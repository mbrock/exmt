defmodule Exmt.CLI.Commands.GetConfig do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias MTProto.{SessionData, TelegramKeys}
  alias MTProto.SessionStore.File, as: FileStore
  alias MTProto.Telegram.API
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

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

  @impl true
  def command, do: "get-config"

  @impl true
  def aliases, do: ["get_config"]

  @impl true
  def summary, do: "Perform help.getConfig using the Telegram client"

  @impl true
  def usage do
    """
    usage:
      exmt get-config
      exmt get-config --host 149.154.167.50 --dc-id 2
      TDLIB_API_ID=123456 exmt get-config --session-file .exmt/demo.term --timeout 60000 --verbose
    """
  end

  @impl true
  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      with {:ok, run} <- build_run(argv),
           :ok <- print_banner(run),
           {:ok, summary} <- run_scenario(run) do
        print_summary(summary, run.opts)
        :ok
      else
        {:error, reason} ->
          IO.puts(:stderr, "error: #{format_error(reason)}")
          IO.puts(:stderr, usage())
          {:error, reason}
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp build_run(argv) do
    with {:ok, opts} <- parse_args(argv),
         {:ok, api_id, api_id_source} <- fetch_api_id(),
         session_file = session_file(opts),
         {:ok, stored_session_data} <- FileStore.load(session_file) do
      {:ok,
       %{
         opts: opts,
         api_id: api_id,
         api_id_source: api_id_source,
         session_file: session_file,
         stored_session_data: stored_session_data,
         endpoints: endpoints(opts, stored_session_data)
       }}
    end
  end

  defp parse_args(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          dc_id: :integer,
          host: :string,
          port: :integer,
          session_file: :string,
          timeout: :integer,
          verbose: :boolean
        ]
      )

    cond do
      invalid != [] -> {:error, {:invalid_switches, invalid}}
      rest != [] -> {:error, {:unexpected_arguments, rest}}
      true -> {:ok, opts}
    end
  end

  defp fetch_api_id do
    with :error <- fetch_api_id_from_env() do
      {:error, :missing_api_id}
    end
  end

  defp fetch_api_id_from_env do
    Enum.find_value(@api_id_env_vars, :error, fn env_var ->
      case System.get_env(env_var) do
        nil -> nil
        value -> parse_api_id(value, {:env, env_var})
      end
    end)
  end

  defp parse_api_id(value, source) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {api_id, ""} -> {:ok, api_id, source}
      _ -> {:error, {:invalid_api_id, source}}
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

  defp run_scenario(run) do
    try_endpoints(run.endpoints, run)
  end

  defp try_endpoints(endpoints, run) do
    Enum.reduce_while(endpoints, {:error, []}, fn endpoint,
                                                  {:error, errors} ->
      print_attempt(endpoint)

      case try_endpoint(endpoint, run) do
        {:ok, summary} ->
          {:halt, {:ok, summary}}

        {:error, reason} ->
          IO.puts(
            :stderr,
            "  failed: #{format_endpoint(endpoint)}: #{format_error(reason)}"
          )

          {:cont, {:error, [{endpoint, reason} | errors]}}
      end
    end)
    |> case do
      {:ok, summary} ->
        {:ok, summary}

      {:error, []} ->
        {:error, :no_endpoints}

      {:error, errors} ->
        {:error, {:all_endpoints_failed, Enum.reverse(errors)}}
    end
  end

  defp try_endpoint(endpoint, run) do
    endpoint
    |> client_opts(run)
    |> start_client()
    |> with_client(fn client ->
      connect_and_get_config(client, endpoint, run)
    end)
  end

  defp connect_and_get_config(client, endpoint, run) do
    with {:ok, session_id} <- connect_client(client, run.opts),
         {:ok, decoded} <- get_config(client, run) do
      {:ok,
       %{
         endpoint: endpoint,
         session_id: session_id,
         layer: API.current_layer(),
         result: %{kind: :decoded, decoded: decoded}
       }}
    end
  end

  defp client_opts(endpoint, run) do
    [
      host: endpoint.host,
      port: endpoint.port,
      public_keys: TelegramKeys.main_keys!(),
      notify_to: self(),
      pq_inner_data_mode: :dc,
      dc_id: endpoint.dc_id,
      session_store: {FileStore, run.session_file},
      load_session_data: false
    ]
    |> maybe_put_session_data(session_data_for_endpoint(endpoint, run))
  end

  defp session_data_for_endpoint(
         endpoint,
         %{stored_session_data: %SessionData{dc_id: dc_id} = session_data}
       )
       when dc_id == endpoint.dc_id do
    session_data
  end

  defp session_data_for_endpoint(_endpoint, _run), do: nil

  defp maybe_put_session_data(opts, %SessionData{} = session_data) do
    Keyword.put(opts, :session_data, session_data)
  end

  defp maybe_put_session_data(opts, nil), do: opts

  defp start_client(opts) do
    TelegramClient.start_link(opts)
  end

  defp with_client({:ok, client}, fun) when is_function(fun, 1) do
    try do
      fun.(client)
    after
      stop_client(client)
    end
  end

  defp with_client({:error, reason}, _fun), do: {:error, reason}

  defp connect_client(client, opts) do
    TelegramClient.connect(client,
      timeout: timeout(opts),
      on_mtproto_event: verbose_callback(:auth, opts)
    )
  end

  defp get_config(client, run) do
    TelegramClient.get_config_sync(client,
      api_id: run.api_id,
      request: :help_get_config,
      timeout: timeout(run.opts),
      on_mtproto_event: verbose_callback(:rpc, run.opts),
      on_telegram_event: verbose_callback(:rpc, run.opts)
    )
  end

  defp print_banner(run) do
    IO.puts(
      "Using api_id from #{format_api_id_source(run.api_id_source)}; " <>
        "layer=#{API.current_layer()} timeout=#{timeout(run.opts)}ms"
    )

    IO.puts("Session file: #{run.session_file}")

    case run.stored_session_data do
      %SessionData{dc_id: dc_id} ->
        IO.puts("Stored session: present for dc #{dc_id}")

      nil ->
        IO.puts("Stored session: none")
    end

    IO.puts(
      "Endpoints: " <> Enum.map_join(run.endpoints, ", ", &format_endpoint/1)
    )

    :ok
  end

  defp print_attempt(endpoint) do
    IO.puts("Trying #{format_endpoint(endpoint)}")
  end

  defp maybe_print_event(_phase, event, true) do
    IO.puts("  event: #{inspect(event, pretty: true)}")
  end

  defp verbose_callback(phase, opts) when is_list(opts) do
    verbose_callback(phase, Keyword.get(opts, :verbose, false))
  end

  defp verbose_callback(phase, true) do
    fn event -> maybe_print_event(phase, event, true) end
  end

  defp verbose_callback(_phase, false), do: nil

  defp print_summary(summary, opts) do
    IO.puts("Success on #{format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Result: #{format_result(summary.result)}")

    if Keyword.get(opts, :verbose, false) do
      IO.puts("Decoded:")
      IO.puts(inspect(summary.result, pretty: true, limit: :infinity))
    end
  end

  defp format_result(%{kind: :decoded, decoded: decoded}) do
    format_decoded(decoded)
  end

  defp format_decoded(%Decoded{
         tl_name: "gzip_packed",
         fields: %{unpacked: unpacked}
       }) do
    "gzip_packed -> " <> format_decoded(unpacked)
  end

  defp format_decoded(%Decoded{
         tl_name: "config",
         constructor_id: constructor_id,
         fields: %{this_dc: this_dc, dc_options: dc_options}
       }) do
    "config##{hex32(constructor_id)} this_dc=#{this_dc} dc_options=#{length(dc_options)}"
  end

  defp format_decoded(%Decoded{
         tl_name: tl_name,
         constructor_id: constructor_id
       }) do
    "#{tl_name}##{hex32(constructor_id)}"
  end

  defp format_api_id_source({:env, env_var}), do: "$#{env_var}"

  defp format_error({:invalid_switches, invalid}), do: inspect(invalid)
  defp format_error({:unexpected_arguments, args}), do: inspect(args)

  defp format_error({:all_endpoints_failed, errors}) do
    Enum.map_join(errors, "; ", fn {endpoint, reason} ->
      "#{format_endpoint(endpoint)} => #{format_error(reason)}"
    end)
  end

  defp format_error({:connection_exit, reason}),
    do: "connection exited: #{inspect(reason)}"

  defp format_error({:invalid_api_id, source}),
    do: "invalid api_id in #{format_api_id_source(source)}"

  defp format_error(:missing_api_id),
    do: "could not find TDLIB_API_ID/TELEGRAM_API_ID"

  defp format_error(:no_endpoints), do: "no endpoints configured"

  defp format_error(:session_timeout),
    do: "timed out waiting for session setup"

  defp format_error(:rpc_timeout), do: "timed out waiting for rpc_result"
  defp format_error(reason), do: inspect(reason)

  defp format_endpoint(endpoint) do
    "#{List.to_string(endpoint.host)}:#{endpoint.port} (dc #{endpoint.dc_id})"
  end

  defp hex32(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp timeout(opts) do
    Keyword.get(opts, :timeout, @default_timeout)
  end

  defp stop_client(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  catch
    :exit, _reason -> :ok
  end
end
