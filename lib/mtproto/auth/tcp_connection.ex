defmodule MTProto.Auth.TCPConnection do
  @moduledoc """
  Thin TCP adapter around the pure MTProto auth-key exchange state machine.

  This process owns:

    * the TCP socket
    * abridged transport framing
    * the plain MTProto envelope and message ids
    * wall-clock access for auth timestamps
    * randomness needed by the handshake

  Protocol state stays inside `MTProto.Auth.KeyExchange`.
  """

  use GenServer

  alias MTProto.Auth.KeyExchange
  alias MTProto.{MessageId, PlainMessage}
  alias MTProto.Socket.GenTCP
  alias MTProto.Transport.Abridged

  @step2_random_bytes 512
  @step3_random_bytes 512

  @type state :: %__MODULE__{
          socket: term(),
          socket_mod: module(),
          transport: module(),
          transport_decoder: term(),
          transport_started?: boolean(),
          key_exchange: KeyExchange.t(),
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

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    public_keys = Keyword.fetch!(opts, :public_keys)
    socket_mod = Keyword.get(opts, :socket_mod, GenTCP)
    socket_opts = Keyword.get(opts, :socket_opts, default_socket_opts())
    transport = Keyword.get(opts, :transport, Abridged)

    with {:ok, socket} <- socket_mod.connect(host, port, socket_opts),
         :ok <- socket_mod.setopts(socket, active: :once) do
      {:ok,
       %__MODULE__{
         socket: socket,
         socket_mod: socket_mod,
         transport: transport,
         transport_decoder: transport.new_decoder(),
         key_exchange: KeyExchange.new(),
         public_keys: public_keys,
         notify_to: Keyword.get(opts, :notify_to, self()),
         dc_id: Keyword.get(opts, :dc_id, 0),
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
  end

  @impl true
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

  defp execute_effect(state, {:notify, event}) do
    notify(state, event)
    {:ok, state}
  end

  defp send_plain_tl(state, body) do
    msg_id = MessageId.next(state.last_msg_id, state.now_ns_fun.())

    packet =
      %PlainMessage{message_id: msg_id, body: body}
      |> PlainMessage.encode()
      |> state.transport.encode()

    with :ok <- maybe_send_transport_prefix(state),
         :ok <- state.socket_mod.send(state.socket, packet) do
      notify(state, {:plain_message_sent, msg_id, body})

      {:ok,
       %{
         state
         | transport_started?: true,
           last_msg_id: msg_id
       }}
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
end
