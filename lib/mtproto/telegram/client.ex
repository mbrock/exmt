defmodule MTProto.Telegram.Client do
  @moduledoc """
  Telegram API client on top of `MTProto.Client`.

  This module owns the Telegram-specific layer:

    * wrapping queries in `invokeWithLayer(initConnection(...))`
    * tracking expected Telegram result types
    * decoding Telegram API results and surfacing Telegram-specific events
    * convenience helpers for waiting until a session is ready or a request
      finishes

  The underlying `MTProto.Client` remains responsible for transport, auth-key
  exchange, durable session state, and raw MTProto message flow.
  """

  use GenServer

  alias MTProto.Client, as: MTProtoClient
  alias MTProto.Telegram.{API, Result}

  @telegram_client_opts [:name, :notify_to]
  @default_wait_timeout 30_000

  @type state :: %__MODULE__{
          mtproto_client: pid(),
          notify_to: pid(),
          session_id: integer() | nil,
          auth_in_progress?: boolean(),
          pending_results: %{optional(non_neg_integer()) => binary()}
        }

  defstruct [
    :mtproto_client,
    :notify_to,
    :session_id,
    auth_in_progress?: false,
    pending_results: %{}
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

  @spec connect(GenServer.server(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def connect(server, opts \\ []) do
    with {:ok, server_pid} <- resolve_server_pid(server),
         {timeout, wait_opts} = pop_wait_opts(opts),
         deadline = deadline_from_timeout(timeout),
         {:ok, session_state} <-
           GenServer.call(
             server,
             {:connect, Keyword.take(opts, [:nonce])},
             remaining_timeout(deadline)
           ) do
      case session_state do
        {:ready, session_id} ->
          {:ok, session_id}

        :waiting ->
          wait_for_session_ready_until(server_pid, deadline, wait_opts)
      end
    end
  end

  @spec session_data(GenServer.server()) :: MTProto.SessionData.t() | nil
  def session_data(server) do
    GenServer.call(server, :session_data)
  end

  @spec invoke(GenServer.server(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def invoke(server, query, opts \\ []) do
    GenServer.call(server, {:invoke, query, opts})
  end

  @spec invoke_sync(GenServer.server(), binary(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def invoke_sync(server, query, opts \\ []) do
    with {:ok, server_pid} <- resolve_server_pid(server),
         {timeout, wait_opts} = pop_wait_opts(opts),
         deadline = deadline_from_timeout(timeout),
         {:ok, _session_id} <-
           connect(
             server,
             opts
             |> Keyword.take([:nonce, :on_mtproto_event, :on_telegram_event])
             |> Keyword.put(:timeout, remaining_timeout(deadline))
           ),
         {:ok, request_id} <-
           invoke(
             server,
             query,
             Keyword.drop(
               opts,
               [:timeout, :nonce, :on_mtproto_event, :on_telegram_event]
             )
           ) do
      wait_for_request_result_until(
        server_pid,
        request_id,
        normalize_result_type_value(opts),
        deadline,
        wait_opts
      )
    end
  end

  @spec get_config(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def get_config(server, opts \\ []) do
    invoke(
      server,
      API.help_get_config(),
      opts
      |> Keyword.put_new(:request, :help_get_config)
      |> Keyword.put_new(:result_type, "Config")
    )
  end

  @spec get_config_sync(GenServer.server(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def get_config_sync(server, opts \\ []) do
    invoke_sync(
      server,
      API.help_get_config(),
      opts
      |> Keyword.put_new(:request, :help_get_config)
      |> Keyword.put_new(:result_type, "Config")
    )
  end

  @spec send_code(GenServer.server(), binary(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def send_code(server, phone_number, api_hash, opts \\ []) do
    GenServer.call(server, {:send_code, phone_number, api_hash, opts})
  end

  @spec send_code_sync(GenServer.server(), binary(), binary(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_code_sync(server, phone_number, api_hash, opts \\ []) do
    with {:ok, query} <- API.auth_send_code(phone_number, api_hash, opts) do
      invoke_sync(
        server,
        query,
        opts
        |> Keyword.put_new(:request, :auth_send_code)
        |> Keyword.put_new(:result_type, "auth.SentCode")
      )
    end
  end

  @spec sign_in(GenServer.server(), binary(), binary(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sign_in(server, phone_number, phone_code_hash, phone_code, opts \\ []) do
    GenServer.call(
      server,
      {:sign_in, phone_number, phone_code_hash, phone_code, opts}
    )
  end

  @spec sign_in_sync(
          GenServer.server(),
          binary(),
          binary(),
          binary(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def sign_in_sync(
        server,
        phone_number,
        phone_code_hash,
        phone_code,
        opts \\ []
      ) do
    with {:ok, query} <-
           API.auth_sign_in(
             phone_number,
             phone_code_hash,
             phone_code,
             opts
           ) do
      invoke_sync(
        server,
        query,
        opts
        |> Keyword.put_new(:request, :auth_sign_in)
        |> Keyword.put_new(:result_type, "auth.Authorization")
      )
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    notify_to = Keyword.get(opts, :notify_to, self())

    with {:ok, mtproto_client} <- start_mtproto_client(opts) do
      {:ok,
       %__MODULE__{
         mtproto_client: mtproto_client,
         notify_to: notify_to,
         session_id: nil,
         auth_in_progress?: false,
         pending_results: %{}
       }}
    end
  end

  @impl true
  def handle_call({:begin_auth_key_exchange, opts}, _from, state) do
    {:reply,
     MTProtoClient.begin_auth_key_exchange(state.mtproto_client, opts), state}
  end

  def handle_call({:connect, opts}, _from, state) do
    case state.session_id do
      session_id when is_integer(session_id) ->
        {:reply, {:ok, {:ready, session_id}}, state}

      nil ->
        case ensure_auth_in_progress(state, opts) do
          {:ok, next_state} ->
            {:reply, {:ok, :waiting}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:session_data, _from, state) do
    {:reply, MTProtoClient.session_data(state.mtproto_client), state}
  end

  def handle_call({:invoke, query, opts}, _from, state) do
    invoke_telegram_query(state, query, opts)
  end

  def handle_call({:send_code, phone_number, api_hash, opts}, _from, state) do
    opts =
      opts
      |> Keyword.put_new(:request, :auth_send_code)
      |> Keyword.put_new(:result_type, "auth.SentCode")

    with {:ok, query} <- API.auth_send_code(phone_number, api_hash, opts) do
      invoke_telegram_query(state, query, opts)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:sign_in, phone_number, phone_code_hash, phone_code, opts},
        _from,
        state
      ) do
    opts =
      opts
      |> Keyword.put_new(:request, :auth_sign_in)
      |> Keyword.put_new(:result_type, "auth.Authorization")

    with {:ok, query} <-
           API.auth_sign_in(
             phone_number,
             phone_code_hash,
             phone_code,
             opts
           ) do
      invoke_telegram_query(state, query, opts)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:mtproto, mtproto_client, {:session_ready, session_id} = event},
        %__MODULE__{mtproto_client: mtproto_client} = state
      ) do
    next_state = %{state | session_id: session_id, auth_in_progress?: false}
    notify_mtproto(next_state, event)
    {:noreply, next_state}
  end

  def handle_info(
        {:mtproto, mtproto_client, {:rpc_result, request_id, result} = event},
        %__MODULE__{mtproto_client: mtproto_client} = state
      ) do
    notify_mtproto(state, event)
    maybe_notify_decoded_result(state, request_id, result)
    {:noreply, state}
  end

  def handle_info(
        {:mtproto, mtproto_client,
         {:rpc_request_result, request_id, request, result} = event},
        %__MODULE__{mtproto_client: mtproto_client} = state
      ) do
    notify_mtproto(state, event)

    {:noreply,
     maybe_notify_decoded_request_result(state, request_id, request, result)}
  end

  def handle_info(
        {:mtproto, mtproto_client, event},
        %__MODULE__{mtproto_client: mtproto_client} = state
      ) do
    notify_mtproto(state, event)
    {:noreply, state}
  end

  def handle_info(
        {:EXIT, mtproto_client, reason},
        %__MODULE__{mtproto_client: mtproto_client} = state
      ) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_mtproto_client(opts) do
    opts
    |> Keyword.drop(@telegram_client_opts)
    |> Keyword.put(:notify_to, self())
    |> MTProtoClient.start_link()
  end

  defp ensure_auth_in_progress(
         %__MODULE__{auth_in_progress?: true} = state,
         _opts
       ),
       do: {:ok, state}

  defp ensure_auth_in_progress(%__MODULE__{} = state, opts) do
    case MTProtoClient.begin_auth_key_exchange(
           state.mtproto_client,
           Keyword.take(opts, [:nonce])
         ) do
      :ok ->
        {:ok, %{state | auth_in_progress?: true}}

      {:error, :session_already_ready} ->
        {:ok, state}

      {:error, :already_started} ->
        {:ok, %{state | auth_in_progress?: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_result_type(opts) do
    case Keyword.fetch(opts, :result_type) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, result_type} when is_binary(result_type) ->
        {:ok, result_type}

      {:ok, result_type} when is_atom(result_type) ->
        {:ok, Atom.to_string(result_type)}

      {:ok, _result_type} ->
        {:error, {:invalid_option, :result_type}}

      :error ->
        {:ok, nil}
    end
  end

  defp normalize_result_type_value(opts) do
    case normalize_result_type(opts) do
      {:ok, result_type} -> result_type
      {:error, _reason} -> nil
    end
  end

  defp invoke_telegram_query(state, query, opts) do
    opts =
      opts
      |> Keyword.put_new(:request, :telegram_request)
      |> Keyword.put_new(:result_type, nil)

    with {:ok, result_type} <- normalize_result_type(opts),
         {:ok, wrapped_query} <- API.wrap_request(query, opts),
         {:ok, request_id} <-
           MTProtoClient.invoke(
             state.mtproto_client,
             wrapped_query,
             request_opts(opts)
           ) do
      {:reply, {:ok, request_id},
       track_request(state, request_id, result_type)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp request_opts(opts) do
    Keyword.take(opts, [:padding_bytes, :request])
  end

  defp track_request(state, _request_id, nil), do: state

  defp track_request(%__MODULE__{} = state, request_id, result_type) do
    put_in(state.pending_results[request_id], result_type)
  end

  defp maybe_notify_decoded_result(
         %__MODULE__{pending_results: pending_results} = state,
         request_id,
         result
       ) do
    case Map.fetch(pending_results, request_id) do
      {:ok, result_type} ->
        case Result.decode(result, type: result_type) do
          {:ok, decoded} ->
            notify_telegram(
              state,
              {:rpc_result_decoded, request_id, result, decoded}
            )

            if Result.rpc_error?(decoded) do
              notify_telegram(
                state,
                {:rpc_error, request_id, result, decoded}
              )
            end

          {:error, _reason} ->
            :ok
        end

      :error ->
        :ok
    end
  end

  defp maybe_notify_decoded_request_result(
         %__MODULE__{pending_results: pending_results} = state,
         request_id,
         request,
         result
       ) do
    {result_type, pending_results} = Map.pop(pending_results, request_id)
    next_state = %{state | pending_results: pending_results}

    case result_type do
      nil ->
        next_state

      result_type ->
        case Result.decode(result, type: result_type) do
          {:ok, decoded} ->
            notify_telegram(
              next_state,
              {:rpc_request_result_decoded, request_id, request, result,
               decoded}
            )

            if Result.rpc_error?(decoded) do
              notify_telegram(
                next_state,
                {:rpc_request_error, request_id, request, result, decoded}
              )
            end

            next_state

          {:error, reason} ->
            notify_telegram(
              next_state,
              {:rpc_request_result_decode_error, request_id, request,
               result_type, reason}
            )

            next_state
        end
    end
  end

  defp notify_mtproto(%__MODULE__{notify_to: notify_to}, event) do
    send(notify_to, {:mtproto, self(), event})
  end

  defp notify_telegram(%__MODULE__{notify_to: notify_to}, event) do
    send(notify_to, {:telegram, self(), event})
  end

  defp resolve_server_pid(server) when is_pid(server), do: {:ok, server}

  defp resolve_server_pid(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :noproc}
    end
  end

  defp pop_wait_opts(opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_wait_timeout)
    {timeout, Keyword.take(opts, [:on_mtproto_event, :on_telegram_event])}
  end

  defp deadline_from_timeout(timeout)
       when is_integer(timeout) and timeout >= 0 do
    System.monotonic_time(:millisecond) + timeout
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp wait_for_session_ready_until(server_pid, deadline, wait_opts) do
    receive do
      {:mtproto, ^server_pid, {:session_ready, session_id}} ->
        {:ok, session_id}

      {:mtproto, ^server_pid, event} ->
        maybe_notify_waiter(wait_opts, :on_mtproto_event, event)
        wait_for_session_ready_until(server_pid, deadline, wait_opts)

      {:telegram, ^server_pid, event} ->
        maybe_notify_waiter(wait_opts, :on_telegram_event, event)
        wait_for_session_ready_until(server_pid, deadline, wait_opts)

      {:EXIT, ^server_pid, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :session_timeout}
    end
  end

  defp wait_for_request_result_until(
         server_pid,
         request_id,
         nil,
         deadline,
         wait_opts
       ) do
    receive do
      {:mtproto, ^server_pid,
       {:rpc_request_result, ^request_id, _request, result}} ->
        {:ok, result}

      {:mtproto, ^server_pid, event} ->
        maybe_notify_waiter(wait_opts, :on_mtproto_event, event)

        wait_for_request_result_until(
          server_pid,
          request_id,
          nil,
          deadline,
          wait_opts
        )

      {:telegram, ^server_pid, event} ->
        maybe_notify_waiter(wait_opts, :on_telegram_event, event)

        wait_for_request_result_until(
          server_pid,
          request_id,
          nil,
          deadline,
          wait_opts
        )

      {:EXIT, ^server_pid, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :rpc_timeout}
    end
  end

  defp wait_for_request_result_until(
         server_pid,
         request_id,
         _result_type,
         deadline,
         wait_opts
       ) do
    receive do
      {:telegram, ^server_pid,
       {:rpc_request_result_decoded, ^request_id, _request, _result, decoded}} ->
        if Result.rpc_error?(decoded) do
          {:error, {:rpc_error, decoded}}
        else
          {:ok, decoded}
        end

      {:telegram, ^server_pid,
       {:rpc_request_result_decode_error, ^request_id, _request, _result_type,
        reason}} ->
        {:error, {:decode_error, reason}}

      {:mtproto, ^server_pid, event} ->
        maybe_notify_waiter(wait_opts, :on_mtproto_event, event)

        wait_for_request_result_until(
          server_pid,
          request_id,
          :decoded,
          deadline,
          wait_opts
        )

      {:telegram, ^server_pid, event} ->
        maybe_notify_waiter(wait_opts, :on_telegram_event, event)

        wait_for_request_result_until(
          server_pid,
          request_id,
          :decoded,
          deadline,
          wait_opts
        )

      {:EXIT, ^server_pid, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :rpc_timeout}
    end
  end

  defp maybe_notify_waiter(wait_opts, key, event) do
    case Keyword.get(wait_opts, key) do
      callback when is_function(callback, 1) -> callback.(event)
      _ -> :ok
    end
  end
end
