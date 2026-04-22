defmodule MTProto.Scripts.HelpGetConfig do
  @moduledoc """
  Small live runner for exercising the current MTProto client against Telegram.

  The built-in bootstrap DC endpoints are only fallbacks to get the first
  `help.getConfig` response. Once the request succeeds, the returned `Config`
  should be treated as the source of truth for current DC addresses.
  """

  alias MTProto.{API, Client, TL, TelegramKeys}

  @config 0xCC1A241E
  @gzip_packed 0x3072CFA1
  @rpc_error 0x2144CA19

  @default_timeout 30_000

  @bootstrap_endpoints [
    %{dc_id: 1, host: ~c"149.154.175.58", port: 443},
    %{dc_id: 2, host: ~c"149.154.167.50", port: 443},
    %{dc_id: 3, host: ~c"149.154.175.100", port: 443},
    %{dc_id: 4, host: ~c"149.154.167.91", port: 443},
    %{dc_id: 5, host: ~c"91.108.56.151", port: 443}
  ]

  @api_id_env_vars ["TDLIB_API_ID", "TELEGRAM_API_ID"]

  def main(argv) do
    Mix.Task.run("app.start")

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      with {:ok, opts} <- parse_args(argv),
           {:ok, api_id, api_id_source} <- fetch_api_id(),
           endpoints = endpoints(opts),
           :ok <- print_banner(api_id_source, endpoints, opts),
           {:ok, summary} <- try_endpoints(endpoints, api_id, opts) do
        print_summary(summary)
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

  defp try_endpoints(endpoints, api_id, opts) do
    Enum.reduce_while(endpoints, {:error, []}, fn endpoint,
                                                  {:error, errors} ->
      print_attempt(endpoint)

      case try_endpoint(endpoint, api_id, opts) do
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

  defp try_endpoint(endpoint, api_id, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    verbose? = Keyword.get(opts, :verbose, false)

    case start_connection(endpoint) do
      {:ok, connection} ->
        try do
          with :ok <- Client.begin_auth_key_exchange(connection),
               {:ok, session_id} <-
                 wait_for_session_ready(connection, timeout, verbose?),
               {:ok, request_id} <-
                 Client.get_config(connection,
                   api_id: api_id,
                   request: :help_get_config
                 ),
               {:ok, result_summary} <-
                 wait_for_rpc_result(
                   connection,
                   request_id,
                   timeout,
                   verbose?
                 ) do
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
          stop_connection(connection)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_connection(endpoint) do
    Client.start_link(
      host: endpoint.host,
      port: endpoint.port,
      public_keys: TelegramKeys.main_keys!(),
      notify_to: self(),
      pq_inner_data_mode: :dc,
      dc_id: endpoint.dc_id
    )
  end

  defp wait_for_session_ready(connection, timeout, verbose?) do
    deadline = now_ms() + timeout
    wait_for_session_ready_until(connection, deadline, verbose?)
  end

  defp wait_for_session_ready_until(connection, deadline, verbose?) do
    receive do
      {:mtproto, ^connection, {:session_ready, session_id}} ->
        {:ok, session_id}

      {:mtproto, ^connection, event} ->
        maybe_print_event(:auth, event, verbose?)
        wait_for_session_ready_until(connection, deadline, verbose?)

      {:EXIT, ^connection, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :session_timeout}
    end
  end

  defp wait_for_rpc_result(connection, request_id, timeout, verbose?) do
    deadline = now_ms() + timeout
    wait_for_rpc_result_until(connection, request_id, deadline, verbose?)
  end

  defp wait_for_rpc_result_until(connection, request_id, deadline, verbose?) do
    receive do
      {:mtproto, ^connection,
       {:rpc_request_result, ^request_id, :help_get_config, result}} ->
        {:ok, summarize_result(result)}

      {:mtproto, ^connection, event} ->
        maybe_print_event(:rpc, event, verbose?)
        wait_for_rpc_result_until(connection, request_id, deadline, verbose?)

      {:EXIT, ^connection, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        {:error, :rpc_timeout}
    end
  end

  defp summarize_result(<<@config::little-unsigned-32, _::binary>> = result) do
    %{
      kind: :config,
      constructor: @config,
      constructor_name: "config",
      bytes: byte_size(result)
    }
  end

  defp summarize_result(<<@rpc_error::little-unsigned-32, rest::binary>>) do
    with {:ok, error_code, rest} <- TL.decode_int(rest),
         {:ok, error_message, <<>>} <- TL.decode_bytes(rest) do
      %{
        kind: :rpc_error,
        constructor: @rpc_error,
        constructor_name: "rpc_error",
        error_code: error_code,
        error_message: error_message
      }
    else
      {:error, reason} ->
        %{
          kind: :rpc_error,
          constructor: @rpc_error,
          constructor_name: "rpc_error",
          decode_error: reason
        }
    end
  end

  defp summarize_result(<<@gzip_packed::little-unsigned-32, rest::binary>>) do
    with {:ok, packed, <<>>} <- TL.decode_bytes(rest),
         {:ok, unpacked} <- gunzip(packed) do
      inner = summarize_result(unpacked)

      %{
        kind: :gzip_packed,
        constructor: @gzip_packed,
        constructor_name: "gzip_packed",
        packed_bytes: byte_size(packed),
        unpacked_bytes: byte_size(unpacked),
        inner: inner
      }
    else
      {:error, reason} ->
        %{
          kind: :gzip_packed,
          constructor: @gzip_packed,
          constructor_name: "gzip_packed",
          decode_error: reason
        }
    end
  end

  defp summarize_result(
         <<constructor::little-unsigned-32, _::binary>> = result
       ) do
    %{
      kind: :unknown,
      constructor: constructor,
      bytes: byte_size(result),
      preview: hex_preview(result)
    }
  end

  defp summarize_result(result) when is_binary(result) do
    %{
      kind: :raw,
      bytes: byte_size(result),
      preview: hex_preview(result)
    }
  end

  defp gunzip(packed) do
    {:ok, :zlib.gunzip(packed)}
  rescue
    error ->
      {:error, {:gzip_error, error}}
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
    |> strip_wrapping_quotes()
    |> Integer.parse()
    |> case do
      {api_id, ""} -> {:ok, api_id, source}
      _ -> {:error, {:invalid_api_id, source}}
    end
  end

  defp strip_wrapping_quotes(<<"'", rest::binary>>) do
    rest
    |> String.trim_trailing("'")
    |> String.trim()
  end

  defp strip_wrapping_quotes(<<"\"", rest::binary>>) do
    rest
    |> String.trim_trailing("\"")
    |> String.trim()
  end

  defp strip_wrapping_quotes(value), do: value

  defp endpoints(opts) do
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

  defp print_banner(api_id_source, endpoints, opts) do
    IO.puts(
      "Using api_id from #{format_api_id_source(api_id_source)}; " <>
        "layer=#{API.current_layer()} timeout=#{Keyword.get(opts, :timeout, @default_timeout)}ms"
    )

    IO.puts(
      "Endpoints: " <>
        Enum.map_join(endpoints, ", ", &format_endpoint/1)
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

  defp print_summary(summary) do
    IO.puts("Success on #{format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Request id: #{summary.request_id}")
    IO.puts("Result: #{format_result(summary.result)}")
  end

  defp format_result(%{kind: :config, constructor: constructor, bytes: bytes}) do
    "config##{hex32(constructor)} (#{bytes} bytes)"
  end

  defp format_result(%{
         kind: :rpc_error,
         error_code: error_code,
         error_message: error_message
       }) do
    "rpc_error #{error_code}: #{error_message}"
  end

  defp format_result(%{
         kind: :gzip_packed,
         packed_bytes: packed_bytes,
         unpacked_bytes: unpacked_bytes,
         inner: inner
       }) do
    "gzip_packed (#{packed_bytes} packed bytes, #{unpacked_bytes} unpacked bytes) -> " <>
      format_result(inner)
  end

  defp format_result(%{
         kind: :unknown,
         constructor: constructor,
         bytes: bytes,
         preview: preview
       }) do
    "unknown##{hex32(constructor)} (#{bytes} bytes, preview=#{preview})"
  end

  defp format_result(%{kind: :raw, bytes: bytes, preview: preview}) do
    "raw (#{bytes} bytes, preview=#{preview})"
  end

  defp format_result(other), do: inspect(other, pretty: true)

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

  defp stop_connection(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  catch
    :exit, _reason -> :ok
  end

  defp usage do
    IO.puts("""
    usage:
      mix run scripts/help_get_config.exs
      mix run scripts/help_get_config.exs --host 149.154.167.50 --dc-id 2
      TDLIB_API_ID=123456 mix run scripts/help_get_config.exs --timeout 60000 --verbose
    """)
  end
end

case MTProto.Scripts.HelpGetConfig.main(System.argv()) do
  :ok -> :ok
  {:error, _reason} -> System.halt(1)
end
