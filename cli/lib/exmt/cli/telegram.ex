defmodule Exmt.CLI.Telegram do
  @moduledoc false

  alias MTProto.{SessionData, TelegramKeys}
  alias MTProto.SessionStore.File, as: FileStore
  alias MTProto.Telegram.{API, UpdateState}
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.Telegram.RPCError
  alias MTProto.Telegram.UpdateStateStore.File, as: UpdateStateFileStore

  @default_timeout 30_000
  @default_session_file ".exmt/session.term"

  @bootstrap_endpoints [
    %{dc_id: 1, host: ~c"149.154.175.58", port: 443},
    %{dc_id: 2, host: ~c"149.154.167.50", port: 443},
    %{dc_id: 3, host: ~c"149.154.175.100", port: 443},
    %{dc_id: 4, host: ~c"149.154.167.91", port: 443},
    %{dc_id: 5, host: ~c"91.108.56.151", port: 443}
  ]

  @api_id_env_vars ["TDLIB_API_ID", "TELEGRAM_API_ID"]
  @api_hash_env_vars ["TDLIB_API_HASH", "TELEGRAM_API_HASH"]

  @type context :: %{
          required(:opts) => keyword(),
          required(:session_file) => binary(),
          required(:stored_session_data) => SessionData.t() | nil,
          required(:endpoints) => [map()],
          optional(:api_id) => integer(),
          optional(:api_id_source) => {:env, binary()},
          optional(:api_hash) => binary(),
          optional(:api_hash_source) => {:env, binary()}
        }

  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @spec common_switches() :: keyword()
  def common_switches do
    [
      dc_id: :integer,
      host: :string,
      port: :integer,
      session_file: :string,
      timeout: :integer,
      verbose: :boolean
    ]
  end

  @spec run_command((() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def run_command(fun) when is_function(fun, 0) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  @spec build_context(keyword(), keyword()) ::
          {:ok, context()} | {:error, term()}
  def build_context(opts, build_opts \\ []) when is_list(opts) do
    required = Keyword.get(build_opts, :require, [:api_id])

    with {:ok, env_values} <- fetch_required_env(required),
         session_file = session_file(opts),
         {:ok, stored_session_data} <- FileStore.load(session_file) do
      {:ok,
       %{
         opts: opts,
         session_file: session_file,
         stored_session_data: stored_session_data,
         endpoints: endpoints(opts, stored_session_data)
       }
       |> Map.merge(env_values)}
    end
  end

  @spec print_banner(context()) :: :ok
  def print_banner(context) do
    IO.puts(
      "Using #{format_sources(context)}; " <>
        "layer=#{API.current_layer()} timeout=#{timeout(context.opts)}ms"
    )

    IO.puts("Session file: #{context.session_file}")

    case context.stored_session_data do
      %SessionData{dc_id: dc_id} ->
        IO.puts("Stored session: present for dc #{dc_id}")

      nil ->
        IO.puts("Stored session: none")
    end

    IO.puts(
      "Endpoints: " <>
        Enum.map_join(context.endpoints, ", ", &format_endpoint/1)
    )

    :ok
  end

  @spec try_endpoints(
          context(),
          (pid(), map() ->
             {:ok, term()} | {:error, term()})
        ) ::
          {:ok, term()} | {:error, term()}
  def try_endpoints(context, fun) when is_function(fun, 2) do
    do_try_endpoints(context.endpoints, context, fun, [])
  end

  @spec connect(pid(), context()) :: {:ok, integer()} | {:error, term()}
  def connect(client, context) when is_pid(client) do
    TelegramClient.connect(client,
      timeout: timeout(context.opts),
      on_mtproto_event: verbose_callback(context.opts)
    )
  end

  @spec request_opts(context(), keyword()) :: keyword()
  def request_opts(context, opts \\ []) when is_list(opts) do
    [
      api_id: Map.fetch!(context, :api_id),
      timeout: timeout(context.opts),
      on_mtproto_event: verbose_callback(context.opts),
      on_telegram_event: verbose_callback(context.opts)
    ]
    |> Keyword.merge(opts)
  end

  @spec timeout(keyword()) :: integer()
  def timeout(opts) when is_list(opts) do
    Keyword.get(opts, :timeout, @default_timeout)
  end

  @spec update_state_file(context() | binary()) :: binary()
  def update_state_file(%{session_file: session_file}) do
    update_state_file(session_file)
  end

  def update_state_file(session_file) when is_binary(session_file) do
    ext = Path.extname(session_file)

    case ext do
      "" -> session_file <> ".updates"
      _ -> Path.rootname(session_file, ext) <> ".updates" <> ext
    end
  end

  @spec load_update_state(context()) ::
          {:ok, UpdateState.t() | nil} | {:error, term()}
  def load_update_state(context) do
    UpdateStateFileStore.load(update_state_file(context))
  end

  @spec save_update_state(context(), UpdateState.t()) ::
          :ok | {:error, term()}
  def save_update_state(context, %UpdateState{} = update_state) do
    UpdateStateFileStore.save(update_state_file(context), update_state)
  end

  @spec format_endpoint(map()) :: binary()
  def format_endpoint(endpoint) do
    "#{List.to_string(endpoint.host)}:#{endpoint.port} (dc #{endpoint.dc_id})"
  end

  @spec format_error(term()) :: binary()
  def format_error({:invalid_switches, invalid}), do: inspect(invalid)
  def format_error({:unexpected_arguments, args}), do: inspect(args)

  def format_error({:missing_argument, name}),
    do: "missing argument #{name}"

  def format_error({:invalid_api_id, source}),
    do: "invalid api_id in #{format_env_source(source)}"

  def format_error({:invalid_api_hash, source}),
    do: "invalid api_hash in #{format_env_source(source)}"

  def format_error({:invalid_peer, value}),
    do:
      "invalid --peer value #{inspect(value)} (expected self|empty|chat:<id>|user:<id>:<access_hash>|channel:<id>:<access_hash>)"

  def format_error({:all_endpoints_failed, errors}) do
    Enum.map_join(errors, "; ", fn {endpoint, reason} ->
      "#{format_endpoint(endpoint)} => #{format_error(reason)}"
    end)
  end

  def format_error({:connection_exit, reason}),
    do: "connection exited: #{inspect(reason)}"

  def format_error(:missing_api_id),
    do: "could not find TDLIB_API_ID/TELEGRAM_API_ID"

  def format_error(:missing_api_hash),
    do: "could not find TDLIB_API_HASH/TELEGRAM_API_HASH"

  def format_error(:no_endpoints), do: "no endpoints configured"

  def format_error(:session_timeout),
    do: "timed out waiting for session setup"

  def format_error(:rpc_timeout), do: "timed out waiting for rpc_result"

  def format_error({:update_state_store_load_failed, reason}),
    do: "update state load failed: #{inspect(reason)}"

  def format_error({:update_state_store_save_failed, reason}),
    do: "update state save failed: #{inspect(reason)}"

  def format_error(%RPCError{} = error), do: Exception.message(error)
  def format_error(reason), do: inspect(reason)

  @spec parse_peer(binary()) ::
          {:ok,
           :self
           | :empty
           | {:chat, integer()}
           | {:user, integer(), integer()}
           | {:channel, integer(), integer()}}
          | {:error, term()}
  def parse_peer("self"), do: {:ok, :self}
  def parse_peer("empty"), do: {:ok, :empty}

  def parse_peer(value) when is_binary(value) do
    case String.split(value, ":") do
      ["chat", id] ->
        parse_single_int_peer(:chat, id, value)

      ["user", id, access_hash] ->
        parse_double_int_peer(:user, id, access_hash, value)

      ["channel", id, access_hash] ->
        parse_double_int_peer(:channel, id, access_hash, value)

      _ ->
        {:error, {:invalid_peer, value}}
    end
  end

  defp session_file(opts) do
    opts
    |> Keyword.get(:session_file, @default_session_file)
    |> Path.expand()
  end

  defp endpoints(opts, %SessionData{dc_id: dc_id}) do
    opts
    |> endpoints(nil)
    |> Enum.sort_by(fn endpoint ->
      if endpoint.dc_id == dc_id, do: 0, else: 1
    end)
  end

  defp endpoints(opts, _stored_session_data) do
    case Keyword.fetch(opts, :host) do
      {:ok, host} ->
        [
          %{
            dc_id: Keyword.get(opts, :dc_id, 2),
            host: String.to_charlist(host),
            port: Keyword.get(opts, :port, 443)
          }
        ]

      :error ->
        @bootstrap_endpoints
    end
  end

  defp do_try_endpoints([], _context, _fun, []), do: {:error, :no_endpoints}

  defp do_try_endpoints([], _context, _fun, errors) do
    {:error, {:all_endpoints_failed, Enum.reverse(errors)}}
  end

  defp do_try_endpoints([endpoint | rest], context, fun, errors) do
    IO.puts("Trying #{format_endpoint(endpoint)}")

    case with_client(context, endpoint, fn client ->
           fun.(client, endpoint)
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        IO.puts(
          :stderr,
          "  failed: #{format_endpoint(endpoint)}: #{format_error(reason)}"
        )

        errors = [{endpoint, reason} | errors]

        case retry_step(reason, endpoint, rest, context) do
          {:continue, next_endpoints} ->
            do_try_endpoints(next_endpoints, context, fun, errors)

          {:halt, reason} ->
            {:error, reason}
        end
    end
  end

  defp retry_step(%RPCError{migrate_to_dc: dc_id}, endpoint, rest, context)
       when is_integer(dc_id) and dc_id != endpoint.dc_id do
    case take_endpoint_by_dc(rest ++ context.endpoints, dc_id) do
      {nil, next_endpoints} ->
        {:continue, next_endpoints}

      {target_endpoint, next_endpoints} ->
        {:continue, [target_endpoint | next_endpoints]}
    end
  end

  defp retry_step(%RPCError{} = reason, _endpoint, _rest, _context),
    do: {:halt, reason}

  defp retry_step(
         {:decode_error, _reason} = reason,
         _endpoint,
         _rest,
         _context
       ),
       do: {:halt, reason}

  defp retry_step(:rpc_timeout, _endpoint, rest, _context),
    do: {:continue, rest}

  defp retry_step(:session_timeout, _endpoint, rest, _context),
    do: {:continue, rest}

  defp retry_step({:connection_exit, _reason}, _endpoint, rest, _context),
    do: {:continue, rest}

  defp retry_step(_reason, _endpoint, rest, _context),
    do: {:continue, rest}

  defp take_endpoint_by_dc(endpoints, dc_id) do
    Enum.reduce(endpoints, {nil, []}, fn endpoint, {found, acc} ->
      cond do
        endpoint.dc_id == dc_id and is_nil(found) ->
          {endpoint, acc}

        true ->
          {found, [endpoint | acc]}
      end
    end)
    |> then(fn {found, rest} -> {found, Enum.reverse(rest)} end)
  end

  defp fetch_required_env(required) do
    Enum.reduce_while(required, {:ok, %{}}, fn key, {:ok, acc} ->
      case fetch_env(key) do
        {:ok, value, source} ->
          {:cont,
           {:ok,
            acc
            |> Map.put(key, value)
            |> Map.put(:"#{key}_source", source)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_env(:api_id) do
    @api_id_env_vars
    |> fetch_env_value()
    |> parse_api_id()
  end

  defp fetch_env(:api_hash) do
    @api_hash_env_vars
    |> fetch_env_value()
    |> parse_api_hash()
  end

  defp fetch_env_value(env_vars) do
    Enum.find_value(env_vars, :error, fn env_var ->
      case System.get_env(env_var) do
        nil -> nil
        value -> {value, {:env, env_var}}
      end
    end)
  end

  defp parse_api_id(:error), do: {:error, :missing_api_id}

  defp parse_api_id({value, source}) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {api_id, ""} -> {:ok, api_id, source}
      _ -> {:error, {:invalid_api_id, source}}
    end
  end

  defp parse_api_hash(:error), do: {:error, :missing_api_hash}

  defp parse_api_hash({value, source}) do
    value = String.trim(value)

    if value == "" do
      {:error, {:invalid_api_hash, source}}
    else
      {:ok, value, source}
    end
  end

  defp with_client(context, endpoint, fun) do
    context
    |> client_opts(endpoint)
    |> TelegramClient.start_link()
    |> case do
      {:ok, client} ->
        try do
          fun.(client)
        after
          stop_client(client)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp client_opts(context, endpoint) do
    [
      host: endpoint.host,
      port: endpoint.port,
      public_keys: TelegramKeys.main_keys!(),
      notify_to: self(),
      pq_inner_data_mode: :dc,
      dc_id: endpoint.dc_id,
      session_store: {FileStore, context.session_file},
      load_session_data: false
    ]
    |> maybe_put_session_data(
      session_data_for_endpoint(endpoint, context.stored_session_data)
    )
  end

  defp session_data_for_endpoint(
         endpoint,
         %SessionData{dc_id: dc_id} = session_data
       )
       when dc_id == endpoint.dc_id do
    session_data
  end

  defp session_data_for_endpoint(_endpoint, _stored_session_data), do: nil

  defp maybe_put_session_data(opts, %SessionData{} = session_data) do
    Keyword.put(opts, :session_data, session_data)
  end

  defp maybe_put_session_data(opts, nil), do: opts

  defp verbose_callback(opts) when is_list(opts) do
    case Keyword.get(opts, :verbose, false) do
      true ->
        fn event -> IO.puts("  event: #{inspect(event, pretty: true)}") end

      false ->
        nil
    end
  end

  defp format_sources(context) do
    [:api_id, :api_hash]
    |> Enum.flat_map(fn key ->
      case Map.fetch(context, :"#{key}_source") do
        {:ok, source} -> ["#{key} from #{format_env_source(source)}"]
        :error -> []
      end
    end)
    |> Enum.join(", ")
  end

  defp format_env_source({:env, env_var}), do: "$#{env_var}"

  defp parse_single_int_peer(kind, id, original) do
    case parse_integer_string(id) do
      {:ok, parsed} -> {:ok, {kind, parsed}}
      :error -> {:error, {:invalid_peer, original}}
    end
  end

  defp parse_double_int_peer(kind, id, access_hash, original) do
    with {:ok, parsed_id} <- parse_integer_string(id),
         {:ok, parsed_hash} <- parse_integer_string(access_hash) do
      {:ok, {kind, parsed_id, parsed_hash}}
    else
      :error -> {:error, {:invalid_peer, original}}
    end
  end

  defp parse_integer_string(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp stop_client(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  catch
    :exit, _reason -> :ok
  end
end
