defmodule Exmt.CLI.Commands.Follow do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Connection
  alias MTProto.Telegram.UpdateState
  alias MTProto.Telegram.UpdateStateStore.File, as: UpdateStateFileStore

  @impl true
  def command_path, do: ["follow"]

  @impl true
  def usage do
    """
    usage:
      exmt follow
      exmt follow --duration 60000
      exmt follow --session-file .exmt/session.term --timeout 60000 --verbose
    """
  end

  @impl true
  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(context, &follow(&1, &2, context),
               start: &start_connection/2
             ) do
        print_summary(summary)
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
            [
              duration: :integer
            ]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest != [] ->
        {:error, {:unexpected_arguments, rest}}

      true ->
        validate_opts(opts)
    end
  end

  defp validate_opts(opts) do
    case Keyword.fetch(opts, :duration) do
      {:ok, duration} when is_integer(duration) and duration >= 0 ->
        {:ok, opts}

      {:ok, _duration} ->
        {:error, {:invalid_option_value, :duration}}

      :error ->
        {:ok, opts}
    end
  end

  defp start_connection(context, endpoint) do
    context
    |> Telegram.connection_opts(endpoint)
    |> Keyword.put(:api_id, Map.fetch!(context, :api_id))
    |> Keyword.put(:timeout, Telegram.timeout(context.opts))
    |> Keyword.put(
      :update_state_store,
      {UpdateStateFileStore, Telegram.update_state_file(context)}
    )
    |> Connection.start_link()
  end

  defp follow(connection, endpoint, context) do
    with {:ok, ready} <-
           Connection.await_ready(connection, Telegram.timeout(context.opts)),
         :ok <- print_follow_start(endpoint, context, ready),
         :ok <- schedule_stop(context.opts),
         :ok <-
           follow_loop(connection, Keyword.get(context.opts, :verbose, false)) do
      {:ok,
       %{
         endpoint: endpoint,
         session_id: ready.session_id,
         update_state:
           Connection.update_state(connection) || ready.update_state
       }}
    end
  end

  defp print_follow_start(endpoint, context, ready) do
    IO.puts("Connected on #{Telegram.format_endpoint(endpoint)}")
    IO.puts("Session id: #{ready.session_id}")
    IO.puts("Updates file: #{Telegram.update_state_file(context)}")

    IO.puts(
      "Starting from #{source_label(ready.source)} state #{format_update_state(ready.update_state)}"
    )

    IO.puts("Listening for pushed updates. Press Ctrl+C to stop.")
    :ok
  end

  defp schedule_stop(opts) do
    case Keyword.get(opts, :duration) do
      duration when is_integer(duration) and duration >= 0 ->
        Process.send_after(self(), :follow_stop, duration)
        :ok

      _ ->
        :ok
    end
  end

  defp follow_loop(connection, verbose?) do
    receive do
      {:telegram_connection, ^connection, {:update, result}} ->
        IO.inspect(result.top_level, pretty: true, limit: :infinity)
        follow_loop(connection, verbose?)

      {:telegram_connection, ^connection, {:difference, difference}} ->
        IO.inspect(difference, pretty: true, limit: :infinity)
        follow_loop(connection, verbose?)

      {:telegram_connection, ^connection,
       {:ready, _session_id, _state, _source}} ->
        follow_loop(connection, verbose?)

      {:telegram_connection, ^connection, event} ->
        maybe_print_verbose(event, verbose?)
        follow_loop(connection, verbose?)

      {:EXIT, ^connection, reason} ->
        {:error, {:connection_exit, reason}}

      :follow_stop ->
        :ok
    end
  end

  defp maybe_print_verbose(_event, false), do: :ok

  defp maybe_print_verbose(event, true) do
    IO.puts("event: #{inspect(event, pretty: true)}")
  end

  defp print_summary(summary) do
    IO.puts("Stopped on #{Telegram.format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Final state: #{format_update_state(summary.update_state)}")
  end

  defp source_label(:stored), do: "stored"
  defp source_label(:fetched), do: "fresh"

  defp format_update_state(%UpdateState{} = update_state) do
    "pts=#{update_state.pts} qts=#{update_state.qts} date=#{update_state.date} seq=#{update_state.seq}"
  end
end
