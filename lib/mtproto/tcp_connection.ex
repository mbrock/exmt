defmodule MTProto.TCPConnection do
  @moduledoc """
  Thin TCP adapter around the pure MTProto state machines.

  This process owns:

    * the TCP socket
    * abridged transport framing
    * the plain MTProto envelope used during auth bootstrap
    * wall-clock access for auth and session timestamps
    * randomness needed by the handshake

  Protocol state itself stays in `MTProto.Auth.KeyExchange` and
  `MTProto.Session`.
  """

  use GenServer

  alias MTProto.Auth.KeyExchange
  alias MTProto.{MessageId, PlainMessage, Session, SessionData}
  alias MTProto.Socket.GenTCP
  alias MTProto.Transport.Abridged

  @step2_random_bytes 512
  @step3_random_bytes 512
  @session_padding_bytes 1024

  @type state :: %__MODULE__{
          socket: term(),
          socket_mod: module(),
          transport: module(),
          transport_decoder: term(),
          transport_started?: boolean(),
          key_exchange: KeyExchange.t(),
          session: Session.t() | nil,
          session_id: integer(),
          public_keys: [MTProto.Auth.PublicKey.t()],
          notify_to: pid(),
          last_msg_id: non_neg_integer() | nil,
          dc_id: integer(),
          pq_inner_data_mode: :bare | :dc,
          random_bytes_chunks: [binary()],
          now_ns_fun: (-> non_neg_integer()),
          now_sec_fun: (-> integer())
        }

  defstruct [
    :socket,
    :socket_mod,
    :transport,
    :transport_decoder,
    :key_exchange,
    :session,
    :session_id,
    :public_keys,
    :notify_to,
    :last_msg_id,
    :dc_id,
    :pq_inner_data_mode,
    :now_ns_fun,
    :now_sec_fun,
    transport_started?: false,
    random_bytes_chunks: []
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec begin_auth_key_exchange(GenServer.server(), keyword()) ::
          :ok | {:error, term()}
  def begin_auth_key_exchange(server, opts \\ []) do
    GenServer.call(server, {:begin_auth_key_exchange, opts})
  end

  @spec ping(GenServer.server(), integer(), keyword()) ::
          :ok | {:error, term()}
  def ping(server, ping_id, opts \\ []) do
    GenServer.call(server, {:ping, ping_id, opts})
  end

  @spec invoke(GenServer.server(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def invoke(server, body, opts \\ []) do
    GenServer.call(server, {:invoke, body, opts})
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    public_keys = Keyword.get(opts, :public_keys, [])
    socket_mod = Keyword.get(opts, :socket_mod, GenTCP)
    socket_opts = Keyword.get(opts, :socket_opts, default_socket_opts())
    transport = Keyword.get(opts, :transport, Abridged)
    session_id = Keyword.get_lazy(opts, :session_id, &random_session_id/0)
    last_msg_id = Keyword.get(opts, :last_msg_id)
    dc_id = Keyword.get_lazy(opts, :dc_id, fn -> default_dc_id(opts) end)

    with {:ok, socket} <- socket_mod.connect(host, port, socket_opts),
         :ok <- socket_mod.setopts(socket, active: :once),
         {:ok, session} <-
           build_initial_session(opts, session_id, last_msg_id),
         {:ok, state} <-
           init_state(
             socket,
             socket_mod,
             transport,
             public_keys,
             opts,
             session,
             session_id,
             last_msg_id,
             dc_id
           ) do
      case durable_session_data(state) do
        %SessionData{} = session_data ->
          {:ok, state, {:continue, {:notify_session_ready, session_data}}}

        :error ->
          {:ok, state}
      end
    end
  end

  @impl true
  def handle_continue({:notify_session_ready, session_data}, state) do
    notify(state, {:session_data_updated, session_data})
    notify(state, {:session_ready, state.session.session_id})
    {:noreply, state}
  end

  @impl true
  def handle_call(
        {:begin_auth_key_exchange, _opts},
        _from,
        %__MODULE__{session: %Session{}} = state
      ) do
    {:reply, {:error, :session_already_ready}, state}
  end

  def handle_call({:begin_auth_key_exchange, opts}, _from, state) do
    nonce =
      Keyword.get_lazy(opts, :nonce, fn -> :crypto.strong_rand_bytes(16) end)

    case KeyExchange.begin(state.key_exchange, nonce) do
      {:ok, key_exchange, effects} ->
        with {:ok, state} <-
               execute_effects(%{state | key_exchange: key_exchange}, effects) do
          {:reply, :ok, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:ping, _ping_id, _opts},
        _from,
        %__MODULE__{session: nil} = state
      ) do
    {:reply, {:error, :session_not_ready}, state}
  end

  def handle_call(
        {:ping, ping_id, opts},
        _from,
        %__MODULE__{session: session} = state
      ) do
    case Session.send_ping(
           session,
           state.now_ns_fun.(),
           ping_id,
           with_session_padding(opts)
         ) do
      {:ok, next_session, effects} ->
        with {:ok, state} <-
               execute_effects(%{state | session: next_session}, effects) do
          {:reply, :ok, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:invoke, _body, _opts},
        _from,
        %__MODULE__{session: nil} = state
      ) do
    {:reply, {:error, :session_not_ready}, state}
  end

  def handle_call(
        {:invoke, body, opts},
        _from,
        %__MODULE__{session: session} = state
      ) do
    case Session.send_request(
           session,
           state.now_ns_fun.(),
           body,
           with_session_padding(opts)
         ) do
      {:ok, next_session, request_id, effects} ->
        with {:ok, state} <-
               execute_effects(%{state | session: next_session}, effects) do
          {:reply, {:ok, request_id}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, chunk}, %__MODULE__{socket: socket} = state) do
    case handle_tcp_chunk(state, chunk) do
      {:ok, state} ->
        case state.socket_mod.setopts(state.socket, active: :once) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            notify(state, {:socket_error, reason})
            {:stop, reason, state}
        end

      {:error, reason, state} ->
        notify(state, {:connection_error, reason})
        {:stop, reason, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %__MODULE__{socket: socket} = state) do
    notify(state, :closed)
    {:stop, :normal, state}
  end

  def handle_info(
        {:tcp_error, socket, reason},
        %__MODULE__{socket: socket} = state
      ) do
    notify(state, {:socket_error, reason})
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_tcp_chunk(state, chunk) do
    with {:ok, decoder, frames} <-
           state.transport.feed(state.transport_decoder, chunk) do
      Enum.reduce_while(
        frames,
        {:ok, %{state | transport_decoder: decoder}},
        fn frame, {:ok, acc_state} ->
          case handle_frame(acc_state, frame) do
            {:ok, next_state} -> {:cont, {:ok, next_state}}
            {:error, reason} -> {:halt, {:error, reason, acc_state}}
          end
        end
      )
    end
  end

  defp handle_frame(state, {:quick_ack, token}) do
    notify(state, {:quick_ack, token})
    {:ok, state}
  end

  defp handle_frame(%__MODULE__{session: %Session{} = session} = state, frame)
       when is_binary(frame) do
    with {:ok, next_session, effects} <-
           Session.receive_packet(
             session,
             frame,
             state.now_ns_fun.(),
             with_session_padding([])
           ),
         {:ok, state} <-
           execute_effects(%{state | session: next_session}, effects) do
      {:ok, maybe_notify_session_data_change(state, session)}
    end
  end

  defp handle_frame(state, frame) when is_binary(frame) do
    with {:ok, plain_message} <- PlainMessage.decode(frame) do
      notify(
        state,
        {:plain_message_received, plain_message.message_id,
         plain_message.body}
      )

      route_plain_message(state, plain_message.body)
    end
  end

  defp route_plain_message(
         %__MODULE__{
           key_exchange: %KeyExchange{phase: :awaiting_res_pq} = key_exchange
         } = state,
         body
       ) do
    with {random_bytes, state} <-
           take_random_bytes(state, @step2_random_bytes),
         {:ok, next_key_exchange, effects} <-
           KeyExchange.receive_res_pq(key_exchange, body,
             public_keys: state.public_keys,
             random_bytes: random_bytes,
             pq_inner_data_mode: state.pq_inner_data_mode,
             dc_id: state.dc_id
           ),
         {:ok, state} <-
           execute_effects(
             %{state | key_exchange: next_key_exchange},
             effects
           ) do
      {:ok, state}
    end
  end

  defp route_plain_message(
         %__MODULE__{
           key_exchange:
             %KeyExchange{phase: :awaiting_server_dh_params} = key_exchange
         } = state,
         body
       ) do
    with {random_bytes, state} <-
           take_random_bytes(state, @step3_random_bytes),
         {:ok, next_key_exchange, effects} <-
           KeyExchange.receive_server_dh_params(key_exchange, body,
             random_bytes: random_bytes,
             now: state.now_sec_fun.()
           ),
         {:ok, state} <-
           execute_effects(
             %{state | key_exchange: next_key_exchange},
             effects
           ) do
      {:ok, state}
    end
  end

  defp route_plain_message(
         %__MODULE__{
           key_exchange: %KeyExchange{phase: :awaiting_dh_gen} = key_exchange
         } = state,
         body
       ) do
    with {:ok, next_key_exchange, effects} <-
           KeyExchange.receive_dh_gen(key_exchange, body),
         {:ok, state} <-
           execute_effects(
             %{state | key_exchange: next_key_exchange},
             effects
           ) do
      {:ok, state}
    end
  end

  defp route_plain_message(state, body) do
    notify(state, {:unhandled_tl, state.key_exchange.phase, body})
    {:ok, state}
  end

  defp execute_effects(state, effects) do
    Enum.reduce_while(effects, {:ok, state}, fn effect, {:ok, acc_state} ->
      case execute_effect(acc_state, effect) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_effect(state, {:send_tl, body}) do
    send_plain_tl(state, body)
  end

  defp execute_effect(state, {:send_encrypted, payload}) do
    send_encrypted_payload(state, payload)
  end

  defp execute_effect(state, {:notify, {:auth_key_created, result} = event}) do
    with {:ok, session} <- new_session(state, result),
         {:ok, session_data} <-
           SessionData.from_exchange_result(result,
             dc_id: state.dc_id
           ) do
      notify(state, event)
      notify(state, {:session_data_updated, session_data})
      notify(state, {:session_ready, session.session_id})
      {:ok, %{state | session: session}}
    end
  end

  defp execute_effect(state, {:notify, event}) do
    notify(state, event)
    {:ok, state}
  end

  defp send_plain_tl(state, body) do
    msg_id = MessageId.next(state.last_msg_id, state.now_ns_fun.())

    payload =
      %PlainMessage{message_id: msg_id, body: body}
      |> PlainMessage.encode()

    with :ok <- send_transport_payload(state, payload) do
      notify(state, {:plain_message_sent, msg_id, body})

      {:ok,
       %{
         state
         | transport_started?: true,
           last_msg_id: msg_id
       }}
    end
  end

  defp send_encrypted_payload(state, payload) do
    with :ok <- send_transport_payload(state, payload) do
      {:ok, %{state | transport_started?: true}}
    end
  end

  defp send_transport_payload(state, payload) do
    packet = state.transport.encode(payload)

    with :ok <- maybe_send_transport_prefix(state),
         :ok <- state.socket_mod.send(state.socket, packet) do
      :ok
    end
  end

  defp maybe_send_transport_prefix(%__MODULE__{transport_started?: true}),
    do: :ok

  defp maybe_send_transport_prefix(%__MODULE__{} = state) do
    state.socket_mod.send(state.socket, state.transport.client_prefix())
  end

  defp notify(%__MODULE__{notify_to: notify_to}, event) do
    send(notify_to, {:mtproto, self(), event})
  end

  defp take_random_bytes(
         %__MODULE__{random_bytes_chunks: [chunk | rest]} = state,
         _size
       ) do
    {chunk, %{state | random_bytes_chunks: rest}}
  end

  defp take_random_bytes(%__MODULE__{} = state, size) do
    {:crypto.strong_rand_bytes(size), state}
  end

  defp default_socket_opts do
    [:binary, packet: :raw, active: false, nodelay: true]
  end

  defp default_dc_id(opts) do
    case Keyword.fetch(opts, :session_data) do
      {:ok, %SessionData{dc_id: dc_id}} -> dc_id
      _ -> 0
    end
  end

  defp init_state(
         socket,
         socket_mod,
         transport,
         public_keys,
         opts,
         session,
         session_id,
         last_msg_id,
         dc_id
       ) do
    {:ok,
     %__MODULE__{
       socket: socket,
       socket_mod: socket_mod,
       transport: transport,
       transport_decoder: transport.new_decoder(),
       key_exchange: KeyExchange.new(),
       session: session,
       session_id: session_id,
       public_keys: public_keys,
       notify_to: Keyword.get(opts, :notify_to, self()),
       last_msg_id: last_msg_id,
       dc_id: dc_id,
       pq_inner_data_mode: Keyword.get(opts, :pq_inner_data_mode, :bare),
       random_bytes_chunks: Keyword.get(opts, :random_bytes_chunks, []),
       now_ns_fun:
         Keyword.get(opts, :now_ns_fun, fn ->
           System.os_time(:nanosecond)
         end),
       now_sec_fun:
         Keyword.get(opts, :now_sec_fun, fn ->
           System.system_time(:second)
         end)
     }}
  end

  defp build_initial_session(opts, session_id, last_msg_id) do
    case Keyword.fetch(opts, :session_data) do
      {:ok, %SessionData{} = session_data} ->
        Session.new(
          SessionData.to_session_opts(session_data,
            session_id: session_id,
            last_msg_id: last_msg_id
          )
        )

      {:ok, _session_data} ->
        {:error, :invalid_session_data}

      :error ->
        {:ok, nil}
    end
  end

  defp new_session(state, result) do
    Session.new(result,
      session_id: state.session_id,
      last_msg_id: state.last_msg_id
    )
  end

  defp maybe_notify_session_data_change(
         %__MODULE__{session: %Session{} = next_session} = state,
         %Session{} = previous_session
       ) do
    previous = durable_session_data(previous_session, state.dc_id)
    current = durable_session_data(next_session, state.dc_id)

    if current != previous do
      notify(state, {:session_data_updated, current})
    end

    state
  end

  defp maybe_notify_session_data_change(state, _previous_session), do: state

  defp durable_session_data(%__MODULE__{
         session: %Session{} = session,
         dc_id: dc_id
       }) do
    durable_session_data(session, dc_id)
  end

  defp durable_session_data(%__MODULE__{}), do: :error

  defp durable_session_data(%Session{} = session, dc_id) do
    case SessionData.from_session(session, dc_id: dc_id) do
      {:ok, session_data} -> session_data
      {:error, _reason} -> :error
    end
  end

  defp random_session_id do
    <<session_id::little-signed-64>> = :crypto.strong_rand_bytes(8)
    session_id
  end

  defp with_session_padding(opts) do
    Keyword.put_new_lazy(opts, :padding_bytes, fn ->
      :crypto.strong_rand_bytes(@session_padding_bytes)
    end)
  end
end
