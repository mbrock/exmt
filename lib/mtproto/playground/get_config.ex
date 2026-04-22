defmodule MTProto.Playground.GetConfig do
  @moduledoc false

  alias MTProto.{API, Client, SessionData, TelegramKeys}
  alias MTProto.API.Result
  alias MTProto.SessionStore.File, as: FileStore
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

  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      with {:ok, opts} <- parse_args(argv),
           {:ok, api_id, api_id_source} <- fetch_api_id(),
           session_file = session_file(opts),
           {:ok, stored_session_data} <- FileStore.load(session_file),
           endpoints = endpoints(opts, stored_session_data),
           :ok <-
             print_banner(
               api_id_source,
               endpoints,
               opts,
               session_file,
               stored_session_data
             ),
           {:ok, summary} <-
             try_endpoints(
               endpoints,
               api_id,
               opts,
               session_file,
               stored_session_data
             ) do
        print_summary(summary, opts)
        :ok
      else
        {:error, reason} ->
          IO.puts(:stderr, "error: #{format_error(reason)}")
          usage()
          {:error, reason}
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
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

  defp try_endpoints(
         endpoints,
         api_id,
         opts,
         session_file,
         stored_session_data
       ) do
    Enum.reduce_while(endpoints, {:error, []}, fn endpoint,
                                                  {:error, errors} ->
      print_attempt(endpoint)

      case try_endpoint(
             endpoint,
             api_id,
             opts,
             session_file,
             stored_session_data
           ) do
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

  defp try_endpoint(endpoint, api_id, opts, session_file, stored_session_data) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    verbose? = Keyword.get(opts, :verbose, false)

    session_data =
      case stored_session_data do
        %SessionData{dc_id: dc_id} = session_data
        when dc_id == endpoint.dc_id ->
          session_data

        _ ->
          nil
      end

    client_opts = [
      host: endpoint.host,
      port: endpoint.port,
      public_keys: TelegramKeys.main_keys!(),
      notify_to: self(),
      pq_inner_data_mode: :dc,
      dc_id: endpoint.dc_id,
      session_store: {FileStore, session_file},
      load_session_data?: false
    ]

    client_opts =
      case session_data do
        %SessionData{} ->
          Keyword.put(client_opts, :session_data, session_data)

        nil ->
          client_opts
      end

    case Client.start_link(client_opts) do
      {:ok, client} ->
        try do
          with :ok <- maybe_begin_auth_key_exchange(client, session_data),
               {:ok, session_id} <-
                 wait_for_session_ready(client, timeout, verbose?),
               {:ok, request_id} <-
                 Client.get_config(client,
                   api_id: api_id,
                   request: :help_get_config
                 ),
               {:ok, result_summary} <-
                 wait_for_rpc_result(client, request_id, timeout, verbose?) do
            {:ok,
             %{
               endpoint: endpoint,
               session_id: session_id,
               request_id: request_id,
               layer: API.current_layer(),
               result: result_summary
             }}
          end
        after
          stop_client(client)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_begin_auth_key_exchange(_client, %SessionData{}), do: :ok

  defp maybe_begin_auth_key_exchange(client, nil),
    do: Client.begin_auth_key_exchange(client)

  defp wait_for_session_ready(client, timeout, verbose?) do
    deadline = now_ms() + timeout
    wait_for_session_ready_until(client, deadline, verbose?)
  end

  defp wait_for_session_ready_until(client, deadline, verbose?) do
    receive do
      {:mtproto, ^client, {:session_ready, session_id}} ->
        {:ok, session_id}

      {:mtproto, ^client, event} ->
        maybe_print_event(:auth, event, verbose?)
        wait_for_session_ready_until(client, deadline, verbose?)

      {:EXIT, ^client, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :session_timeout}
    end
  end

  defp wait_for_rpc_result(client, request_id, timeout, verbose?) do
    deadline = now_ms() + timeout
    wait_for_rpc_result_until(client, request_id, deadline, verbose?)
  end

  defp wait_for_rpc_result_until(client, request_id, deadline, verbose?) do
    receive do
      {:mtproto, ^client,
       {:rpc_request_result, ^request_id, :help_get_config, result}} ->
        {:ok, summarize_result(result)}

      {:mtproto, ^client, event} ->
        maybe_print_event(:rpc, event, verbose?)
        wait_for_rpc_result_until(client, request_id, deadline, verbose?)

      {:EXIT, ^client, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :rpc_timeout}
    end
  end

  defp summarize_result(result) do
    case Result.decode(result) do
      {:ok, decoded} ->
        %{kind: :decoded, decoded: decoded, bytes: byte_size(result)}

      {:error, reason} ->
        %{
          kind: :raw,
          bytes: byte_size(result),
          preview: hex_preview(result),
          decode_error: reason
        }
    end
  end

  defp print_banner(
         api_id_source,
         endpoints,
         opts,
         session_file,
         stored_session_data
       ) do
    IO.puts(
      "Using api_id from #{format_api_id_source(api_id_source)}; " <>
        "layer=#{API.current_layer()} timeout=#{Keyword.get(opts, :timeout, @default_timeout)}ms"
    )

    IO.puts("Session file: #{session_file}")

    case stored_session_data do
      %SessionData{dc_id: dc_id} ->
        IO.puts("Stored session: present for dc #{dc_id}")

      nil ->
        IO.puts("Stored session: none")
    end

    IO.puts(
      "Endpoints: " <> Enum.map_join(endpoints, ", ", &format_endpoint/1)
    )

    :ok
  end

  defp print_attempt(endpoint) do
    IO.puts("Trying #{format_endpoint(endpoint)}")
  end

  defp maybe_print_event(_phase, event, true) do
    IO.puts("  event: #{inspect(event, pretty: true)}")
  end

  defp maybe_print_event(_phase, _event, false), do: :ok

  defp print_summary(summary, opts) do
    IO.puts("Success on #{format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Request id: #{summary.request_id}")
    IO.puts("Result: #{format_result(summary.result)}")

    if Keyword.get(opts, :verbose, false) do
      IO.puts("Decoded:")
      IO.puts(inspect(summary.result, pretty: true, limit: :infinity))
    end
  end

  defp format_result(%{kind: :decoded, decoded: decoded, bytes: bytes}) do
    "#{format_decoded(decoded)} (#{bytes} bytes)"
  end

  defp format_result(%{
         kind: :raw,
         bytes: bytes,
         preview: preview,
         decode_error: decode_error
       }) do
    "raw (#{bytes} bytes, preview=#{preview}, decode_error=#{inspect(decode_error)})"
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

  defp hex_preview(binary) do
    binary
    |> binary_part(0, min(byte_size(binary), 24))
    |> Base.encode16(case: :lower)
  end

  defp remaining_timeout(deadline) do
    max(deadline - now_ms(), 0)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp stop_client(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  catch
    :exit, _reason -> :ok
  end

  defp usage do
    IO.puts("""
    usage:
      mix mtproto.get_config
      mix mtproto.get_config --host 149.154.167.50 --dc-id 2
      TDLIB_API_ID=123456 mix mtproto.get_config --session-file .exmt/demo.term --timeout 60000 --verbose
    """)
  end
end
