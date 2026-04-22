defmodule MTProto.Telegram.Connection do
  @moduledoc """
  Long-lived Telegram session worker.

  This worker owns a single `MTProto.Telegram.Client`, bootstraps updates
  state, keeps the session alive, and surfaces pushed and reconciled updates to
  its consumer.
  """

  use GenServer

  alias MTProto.Telegram.{API, Client, UpdateState, Updates}

  @connection_opts [
    :name,
    :notify_to,
    :api_id,
    :timeout,
    :keepalive_interval,
    :update_state_store,
    :load_update_state,
    :device_model,
    :system_version,
    :app_version,
    :system_lang_code,
    :lang_pack,
    :lang_code
  ]

  @api_opt_keys [
    :api_id,
    :device_model,
    :system_version,
    :app_version,
    :system_lang_code,
    :lang_pack,
    :lang_code
  ]

  @default_timeout 30_000
  @default_keepalive_interval 30_000

  @type update_state_store :: {module(), term()} | nil

  @type ready_info :: %{
          session_id: integer(),
          update_state: UpdateState.t(),
          source: :stored | :fetched
        }

  @type state :: %__MODULE__{
          client: pid(),
          notify_to: pid(),
          api_opts: keyword(),
          request_timeout: pos_integer(),
          keepalive_interval: pos_integer() | nil,
          update_state_store: update_state_store(),
          load_update_state?: boolean(),
          session_id: integer() | nil,
          update_state: UpdateState.t() | nil,
          next_ping_id: integer(),
          ready_source: :stored | :fetched | nil,
          status: :bootstrapping | :ready | {:error, term()},
          waiters: [GenServer.from()]
        }

  defstruct [
    :client,
    :notify_to,
    :api_opts,
    :request_timeout,
    :keepalive_interval,
    :update_state_store,
    :load_update_state?,
    :session_id,
    :update_state,
    :ready_source,
    next_ping_id: 1,
    status: :bootstrapping,
    waiters: []
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec await_ready(GenServer.server(), timeout()) ::
          {:ok, ready_info()} | {:error, term()}
  def await_ready(server, timeout \\ @default_timeout) do
    GenServer.call(server, :await_ready, timeout)
  end

  @spec session_id(GenServer.server()) :: integer() | nil
  def session_id(server) do
    GenServer.call(server, :session_id)
  end

  @spec update_state(GenServer.server()) :: UpdateState.t() | nil
  def update_state(server) do
    GenServer.call(server, :update_state)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, api_opts} <- normalize_api_opts(opts),
         {:ok, request_timeout} <- normalize_timeout(opts),
         {:ok, keepalive_interval} <- normalize_keepalive_interval(opts),
         {:ok, update_state_store} <-
           normalize_update_state_store(
             Keyword.get(opts, :update_state_store)
           ),
         {:ok, client} <- start_client(opts) do
      {:ok,
       %__MODULE__{
         client: client,
         notify_to: Keyword.get(opts, :notify_to, self()),
         api_opts: api_opts,
         request_timeout: request_timeout,
         keepalive_interval: keepalive_interval,
         update_state_store: update_state_store,
         load_update_state?: Keyword.get(opts, :load_update_state, true),
         session_id: nil,
         update_state: nil,
         ready_source: nil,
         next_ping_id: 1,
         status: :bootstrapping,
         waiters: []
       }, {:continue, :bootstrap}}
    end
  end

  @impl true
  def handle_continue(:bootstrap, %__MODULE__{} = state) do
    case bootstrap(state) do
      {:ok, %__MODULE__{} = next_state} ->
        ready_info = ready_info(next_state)

        notify(
          next_state,
          {:ready, ready_info.session_id, ready_info.update_state,
           ready_info.source}
        )

        reply_waiters(next_state.waiters, {:ok, ready_info})

        {:noreply, schedule_keepalive(%{next_state | waiters: []})}

      {:error, reason, %__MODULE__{} = next_state} ->
        notify(next_state, {:bootstrap_error, reason})
        reply_waiters(next_state.waiters, {:error, reason})
        {:stop, reason, %{next_state | status: {:error, reason}, waiters: []}}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, %__MODULE__{status: :ready} = state) do
    {:reply, {:ok, ready_info(state)}, state}
  end

  def handle_call(
        :await_ready,
        _from,
        %__MODULE__{status: {:error, reason}} = state
      ) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(
        :await_ready,
        from,
        %__MODULE__{status: :bootstrapping} = state
      ) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:session_id, _from, %__MODULE__{} = state) do
    {:reply, state.session_id, state}
  end

  def handle_call(:update_state, _from, %__MODULE__{} = state) do
    {:reply, state.update_state, state}
  end

  @impl true
  def handle_info(
        {:telegram, client, {:updates, _message_id, _seq_no, decoded}},
        %__MODULE__{client: client, status: :ready} = state
      ) do
    case handle_pushed_updates(state, decoded) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  def handle_info(
        {:telegram, client, event},
        %__MODULE__{client: client} = state
      ) do
    notify(state, {:telegram, event})
    {:noreply, state}
  end

  def handle_info(
        {:mtproto, client, event},
        %__MODULE__{client: client} = state
      ) do
    notify(state, {:mtproto, event})
    {:noreply, state}
  end

  def handle_info(:keepalive, %__MODULE__{status: :ready} = state) do
    case Client.ping(state.client, state.next_ping_id) do
      :ok ->
        {:noreply,
         schedule_keepalive(%{
           state
           | next_ping_id: state.next_ping_id + 1
         })}

      {:error, reason} ->
        notify(state, {:keepalive_error, reason})
        {:stop, reason, state}
    end
  end

  def handle_info(:keepalive, state), do: {:noreply, state}

  def handle_info(
        {:EXIT, client, reason},
        %__MODULE__{client: client} = state
      ) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp bootstrap(%__MODULE__{} = state) do
    with {:ok, session_id} <-
           Client.connect(state.client, connect_opts(state)),
         {:ok, next_state} <-
           initialize_update_state(%{state | session_id: session_id}) do
      {:ok, %{next_state | status: :ready}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp initialize_update_state(%__MODULE__{} = state) do
    case maybe_load_update_state(state) do
      {:ok, nil} ->
        fetch_current_update_state(state)

      {:ok, %UpdateState{} = update_state} ->
        with {:ok, next_state} <-
               reconcile_update_state(
                 %{state | update_state: update_state},
                 update_state
               ) do
          {:ok, %{next_state | ready_source: :stored}}
        end
    end
  end

  defp fetch_current_update_state(%__MODULE__{} = state) do
    with {:ok, decoded} <- request_sync(state, API.Updates.getState()),
         {:ok, update_state} <- UpdateState.from_decoded(decoded) do
      {:ok,
       state
       |> put_update_state(update_state)
       |> Map.put(:ready_source, :fetched)}
    end
  end

  defp reconcile_update_state(
         %__MODULE__{} = state,
         %UpdateState{} = update_state
       ) do
    request =
      update_state
      |> UpdateState.to_difference_opts()
      |> API.Updates.getDifference()

    with {:ok, decoded} <- request_sync(state, request) do
      case Updates.apply_difference(update_state, decoded) do
        {:ok, difference} ->
          next_state = put_update_state(state, difference.state)
          notify(next_state, {:difference, difference})

          if difference.final? do
            {:ok, next_state}
          else
            reconcile_update_state(next_state, difference.state)
          end

        {:reset, _stale_state} ->
          notify(state, {:reconcile_reset, update_state})
          fetch_current_update_state(state)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_pushed_updates(
         %__MODULE__{update_state: %UpdateState{} = update_state} = state,
         decoded
       ) do
    case Updates.apply_pushed(update_state, decoded) do
      {:ok, result} ->
        next_state = put_update_state(state, result.state)
        notify(next_state, {:update, result})
        {:ok, next_state}

      {:reconcile, _current_state} ->
        notify(state, {:reconcile, decoded})

        case reconcile_update_state(state, update_state) do
          {:ok, next_state} -> {:ok, next_state}
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason} ->
        notify(state, {:update_error, decoded, reason})
        {:ok, state}
    end
  end

  defp handle_pushed_updates(%__MODULE__{} = state, _decoded) do
    {:ok, state}
  end

  defp request_sync(%__MODULE__{} = state, request) do
    Client.request_sync(
      state.client,
      request,
      request_opts(state)
    )
  end

  defp request_opts(%__MODULE__{} = state) do
    state.api_opts
    |> Keyword.put(:timeout, state.request_timeout)
    |> Keyword.put(
      :on_telegram_event,
      &forward_wait_telegram_event(state.client, &1)
    )
  end

  defp connect_opts(%__MODULE__{} = state) do
    [
      timeout: state.request_timeout,
      on_telegram_event: &forward_wait_telegram_event(state.client, &1)
    ]
  end

  defp forward_wait_telegram_event(client, {:updates, _, _, _} = event) do
    send(self(), {:telegram, client, event})
  end

  defp forward_wait_telegram_event(_client, _event), do: :ok

  defp maybe_load_update_state(%__MODULE__{load_update_state?: false}) do
    {:ok, nil}
  end

  defp maybe_load_update_state(%__MODULE__{update_state_store: nil}) do
    {:ok, nil}
  end

  defp maybe_load_update_state(
         %__MODULE__{update_state_store: {module, key}} = state
       ) do
    case module.load(key) do
      {:ok, %UpdateState{} = update_state} ->
        {:ok, update_state}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, _update_state} ->
        notify(
          state,
          {:update_state_store_error, {:load, :invalid_update_state}}
        )

        {:ok, nil}

      {:error, reason} ->
        notify(state, {:update_state_store_error, {:load, reason}})
        {:ok, nil}
    end
  end

  defp put_update_state(%__MODULE__{} = state, %UpdateState{} = update_state) do
    case maybe_save_update_state(state, update_state) do
      :ok ->
        %{state | update_state: update_state}

      {:error, reason} ->
        notify(state, {:update_state_store_error, {:save, reason}})
        %{state | update_state: update_state}
    end
  end

  defp maybe_save_update_state(
         %__MODULE__{update_state_store: nil},
         _update_state
       ),
       do: :ok

  defp maybe_save_update_state(
         %__MODULE__{update_state_store: {module, key}},
         %UpdateState{} = update_state
       ) do
    module.save(key, update_state)
  end

  defp schedule_keepalive(%__MODULE__{keepalive_interval: interval} = state)
       when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :keepalive, interval)
    state
  end

  defp schedule_keepalive(%__MODULE__{} = state), do: state

  defp start_client(opts) do
    opts
    |> Keyword.drop(@connection_opts)
    |> Keyword.put(:notify_to, self())
    |> Client.start_link()
  end

  defp normalize_api_opts(opts) do
    case Keyword.fetch(opts, :api_id) do
      {:ok, api_id} when is_integer(api_id) ->
        {:ok, Keyword.take(opts, @api_opt_keys)}

      {:ok, _api_id} ->
        {:error, {:invalid_option, :api_id}}

      :error ->
        {:error, {:missing_option, :api_id}}
    end
  end

  defp normalize_timeout(opts) do
    case Keyword.get(opts, :timeout, @default_timeout) do
      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _timeout ->
        {:error, {:invalid_option, :timeout}}
    end
  end

  defp normalize_keepalive_interval(opts) do
    case Keyword.get(opts, :keepalive_interval, @default_keepalive_interval) do
      nil ->
        {:ok, nil}

      interval when is_integer(interval) and interval > 0 ->
        {:ok, interval}

      _interval ->
        {:error, {:invalid_option, :keepalive_interval}}
    end
  end

  defp normalize_update_state_store(nil), do: {:ok, nil}

  defp normalize_update_state_store({module, key}) when is_atom(module) do
    {:ok, {module, key}}
  end

  defp normalize_update_state_store(_update_state_store) do
    {:error, :invalid_update_state_store}
  end

  defp ready_info(%__MODULE__{} = state) do
    %{
      session_id: state.session_id,
      update_state: state.update_state,
      source: state.ready_source
    }
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  defp notify(%__MODULE__{notify_to: notify_to}, event) do
    send(notify_to, {:telegram_connection, self(), event})
  end
end
