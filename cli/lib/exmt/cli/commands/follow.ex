defmodule Exmt.CLI.Commands.Follow do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.{API, Client, Result}
  alias MTProto.TL.Runtime.Decoded

  @default_ping_interval 30_000

  @impl true
  def command_path, do: ["follow"]

  @impl true
  def aliases, do: [["f"]]

  @impl true
  def summary, do: "Connect and print the live MTProto/Telegram event stream"

  @impl true
  def usage do
    """
    usage:
      exmt follow
      exmt follow --duration 60000 --ping-interval 10000
      exmt follow --no-get-state
    """
  end

  @impl true
  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, _summary} <-
             Telegram.try_endpoints(context, &follow(&1, &2, context, opts)) do
        :ok
      else
        {:error, reason} ->
          IO.puts(:stderr, "error: #{Telegram.format_error(reason)}")
          IO.puts(:stderr, usage())
          {:error, reason}
      end
    end)
  end

  defp parse_args(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict:
          Telegram.common_switches() ++
            [duration: :integer, ping_interval: :integer, get_state: :boolean]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest != [] ->
        {:error, {:unexpected_arguments, rest}}

      true ->
        {:ok, opts}
    end
  end

  defp follow(client, endpoint, context, opts) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         :ok <- maybe_get_state(client, context, opts) do
      IO.puts("Connected on #{Telegram.format_endpoint(endpoint)}")
      IO.puts("Session id: #{session_id}")
      IO.puts("Listening for events. Press Ctrl+C to stop.")

      schedule_ping(client, ping_interval(opts), 1)

      with :ok <- follow_loop(client, deadline(opts)) do
        {:ok, %{endpoint: endpoint, session_id: session_id}}
      end
    end
  end

  defp maybe_get_state(client, context, opts) do
    case Keyword.get(opts, :get_state, true) do
      false ->
        :ok

      true ->
        case Client.invoke_sync(
               client,
               API.updates_get_state(),
               Telegram.request_opts(
                 context,
                 request: :updates_get_state,
                 result_type: "updates.State"
               )
             ) do
          {:ok, decoded} ->
            IO.puts("Initial state: #{format_decoded(decoded)}")
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp follow_loop(client, deadline) do
    receive do
      {:mtproto, ^client, event} ->
        print_event(:mtproto, event)
        follow_loop(client, deadline)

      {:telegram, ^client, event} ->
        print_event(:telegram, event)
        follow_loop(client, deadline)

      {:follow_ping, ^client, ping_id, interval} ->
        case Client.ping(client, ping_id) do
          :ok ->
            schedule_ping(client, interval, ping_id + 1)
            follow_loop(client, deadline)

          {:error, reason} ->
            {:error, reason}
        end

      {:EXIT, ^client, reason} ->
        {:error, {:connection_exit, reason}}
    after
      remaining_timeout(deadline) ->
        :ok
    end
  end

  defp print_event(kind, event) do
    IO.puts("[#{timestamp()}] #{kind}: #{format_event(event)}")
  end

  defp format_event({:session_data_updated, session_data}) do
    "session_data_updated dc_id=#{session_data.dc_id}"
  end

  defp format_event({:session_ready, session_id}) do
    "session_ready session_id=#{session_id}"
  end

  defp format_event({:pong, msg_id, ping_id}) do
    "pong msg_id=#{msg_id} ping_id=#{ping_id}"
  end

  defp format_event({:msgs_ack, msg_ids}) do
    "msgs_ack #{inspect(msg_ids)}"
  end

  defp format_event({:msgs_ack_sent, msg_id, msg_ids}) do
    "msgs_ack_sent msg_id=#{msg_id} acked=#{inspect(msg_ids)}"
  end

  defp format_event({:rpc_result_decoded, request_id, _result, decoded}) do
    "rpc_result_decoded request_id=#{request_id} #{format_decoded(decoded)}"
  end

  defp format_event(
         {:rpc_request_result_decoded, request_id, request, _result, decoded}
       ) do
    "rpc_request_result_decoded request_id=#{request_id} request=#{inspect(request)} #{format_decoded(decoded)}"
  end

  defp format_event({:rpc_error, request_id, _result, error}) do
    "rpc_error request_id=#{request_id} #{Telegram.format_error(error)}"
  end

  defp format_event({:rpc_request_error, request_id, request, _result, error}) do
    "rpc_request_error request_id=#{request_id} request=#{inspect(request)} #{Telegram.format_error(error)}"
  end

  defp format_event({:unhandled_session_message, message_id, seq_no, body}) do
    "unhandled_session_message message_id=#{message_id} seq_no=#{seq_no} #{format_binary_body(body)}"
  end

  defp format_event(event), do: inspect(event, pretty: true, limit: :infinity)

  defp format_binary_body(body) when is_binary(body) do
    case Result.decode(body) do
      {:ok, decoded} -> format_decoded(decoded)
      {:error, _reason} -> inspect(body, base: :hex, binaries: :as_binaries)
    end
  end

  defp format_decoded(%Decoded{tl_name: "updates.state", fields: fields}) do
    "updates.state pts=#{fields.pts} qts=#{fields.qts} date=#{fields.date} seq=#{fields.seq}"
  end

  defp format_decoded(%Decoded{
         tl_name: "updates.state",
         constructor_id: constructor_id
       }) do
    "updates.state##{hex32(constructor_id)}"
  end

  defp format_decoded(%Decoded{
         tl_name: "gzip_packed",
         fields: %{unpacked: unpacked}
       }) do
    "gzip_packed -> " <> format_decoded(unpacked)
  end

  defp format_decoded(%Decoded{
         tl_name: tl_name,
         constructor_id: constructor_id
       }) do
    "#{tl_name}##{hex32(constructor_id)}"
  end

  defp deadline(opts) do
    case Keyword.get(opts, :duration) do
      duration when is_integer(duration) and duration >= 0 ->
        System.monotonic_time(:millisecond) + duration

      _ ->
        nil
    end
  end

  defp remaining_timeout(nil), do: :infinity

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp ping_interval(opts) do
    Keyword.get(opts, :ping_interval, @default_ping_interval)
  end

  defp schedule_ping(_client, interval, _ping_id)
       when not is_integer(interval) or interval <= 0 do
    :ok
  end

  defp schedule_ping(client, interval, ping_id) do
    Process.send_after(
      self(),
      {:follow_ping, client, ping_id, interval},
      interval
    )
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_time()
    |> Time.to_iso8601()
  end

  defp hex32(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
