defmodule MTProto.Client do
  @moduledoc """
  Thin client process that wraps `MTProto.TCPConnection`.

  This layer stays protocol-light. It is responsible for:

    * optional loading of durable `MTProto.SessionData`
    * forwarding MTProto events from the underlying TCP connection
    * saving updated durable session material through a configured store

  The actual MTProto protocol state continues to live in `MTProto.TCPConnection`
  and the pure state machines below it.
  """

  use GenServer

  alias MTProto.{SessionData, TCPConnection}

  @client_opts [
    :name,
    :notify_to,
    :session_data,
    :session_store,
    :load_session_data
  ]

  @type session_store :: {module(), term()} | nil

  @type state :: %__MODULE__{
          connection: pid(),
          notify_to: pid(),
          session_store: session_store(),
          session_data: SessionData.t() | nil
        }

  defstruct [:connection, :notify_to, :session_store, :session_data]

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

  @spec session_data(GenServer.server()) :: SessionData.t() | nil
  def session_data(server) do
    GenServer.call(server, :session_data)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    notify_to = Keyword.get(opts, :notify_to, self())

    with {:ok, session_store} <-
           normalize_session_store(Keyword.get(opts, :session_store)),
         {:ok, session_data} <- initial_session_data(opts, session_store),
         {:ok, connection} <- start_connection(opts, session_data) do
      {:ok,
       %__MODULE__{
         connection: connection,
         notify_to: notify_to,
         session_store: session_store,
         session_data: session_data
       }}
    end
  end

  @impl true
  def handle_call({:begin_auth_key_exchange, opts}, _from, state) do
    {:reply, TCPConnection.begin_auth_key_exchange(state.connection, opts),
     state}
  end

  def handle_call({:ping, ping_id, opts}, _from, state) do
    {:reply, TCPConnection.ping(state.connection, ping_id, opts), state}
  end

  def handle_call({:invoke, body, opts}, _from, state) do
    {:reply, TCPConnection.invoke(state.connection, body, opts), state}
  end

  def handle_call(:session_data, _from, state) do
    {:reply, state.session_data, state}
  end

  @impl true
  def handle_info(
        {:mtproto, connection,
         {:session_data_updated, %SessionData{} = session_data} = event},
        %__MODULE__{connection: connection} = state
      ) do
    notify(state, event)

    state =
      case maybe_save_session_data(state, session_data) do
        {:ok, next_state} ->
          next_state

        {{:error, reason}, next_state} ->
          notify(next_state, {:session_store_error, {:save, reason}})
          next_state
      end

    {:noreply, state}
  end

  def handle_info(
        {:mtproto, connection, event},
        %__MODULE__{connection: connection} = state
      ) do
    notify(state, event)
    {:noreply, state}
  end

  def handle_info(
        {:EXIT, connection, reason},
        %__MODULE__{connection: connection} = state
      ) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_connection(opts, session_data) do
    opts
    |> Keyword.drop(@client_opts)
    |> Keyword.put(:notify_to, self())
    |> maybe_put_session_data(session_data)
    |> TCPConnection.start_link()
  end

  defp maybe_put_session_data(opts, %SessionData{} = session_data) do
    Keyword.put(opts, :session_data, session_data)
  end

  defp maybe_put_session_data(opts, nil), do: opts

  defp initial_session_data(opts, session_store) do
    case Keyword.fetch(opts, :session_data) do
      {:ok, %SessionData{} = session_data} ->
        {:ok, session_data}

      {:ok, _session_data} ->
        {:error, :invalid_session_data}

      :error ->
        load_session_data(
          session_store,
          Keyword.get(opts, :load_session_data, true)
        )
    end
  end

  defp normalize_session_store(nil), do: {:ok, nil}

  defp normalize_session_store({module, key}) when is_atom(module) do
    {:ok, {module, key}}
  end

  defp normalize_session_store(_session_store),
    do: {:error, :invalid_session_store}

  defp load_session_data(_session_store, false), do: {:ok, nil}
  defp load_session_data(nil, true), do: {:ok, nil}

  defp load_session_data({module, key}, true) do
    case module.load(key) do
      {:ok, %SessionData{} = session_data} ->
        {:ok, session_data}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, _session_data} ->
        {:error, :invalid_session_data}

      {:error, reason} ->
        {:error, {:session_store_load_failed, reason}}
    end
  end

  defp maybe_save_session_data(
         %__MODULE__{session_data: %SessionData{} = current} = state,
         %SessionData{} = session_data
       )
       when current == session_data do
    {:ok, state}
  end

  defp maybe_save_session_data(
         %__MODULE__{session_store: nil} = state,
         %SessionData{} = session_data
       ) do
    {:ok, %{state | session_data: session_data}}
  end

  defp maybe_save_session_data(
         %__MODULE__{session_store: {module, key}} = state,
         %SessionData{} = session_data
       ) do
    next_state = %{state | session_data: session_data}

    case module.save(key, session_data) do
      :ok -> {:ok, next_state}
      {:error, reason} -> {{:error, reason}, next_state}
    end
  end

  defp notify(%__MODULE__{notify_to: notify_to}, event) do
    send(notify_to, {:mtproto, self(), event})
  end
end
