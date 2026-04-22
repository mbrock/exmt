defmodule Exmt.CLI.Commands.GetNearestDC do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["get-nearest-dc"]

  @impl true
  def aliases, do: [["get_nearest_dc"]]

  @impl true
  def summary, do: "Fetch help.getNearestDc"

  @impl true
  def usage do
    """
    usage:
      exmt get-nearest-dc
      exmt get-nearest-dc --session-file .exmt/session.term --timeout 60000 --verbose
    """
  end

  @impl true
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(
               context,
               &get_nearest_dc(&1, &2, context)
             ) do
        print_summary(summary, opts)
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
      OptionParser.parse(argv, strict: Telegram.common_switches())

    cond do
      invalid != [] -> {:error, {:invalid_switches, invalid}}
      rest != [] -> {:error, {:unexpected_arguments, rest}}
      true -> {:ok, opts}
    end
  end

  defp get_nearest_dc(client, endpoint, context) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.help_get_nearest_dc_sync(
             client,
             Telegram.request_opts(context, request: :help_get_nearest_dc)
           ) do
      {:ok, %{endpoint: endpoint, session_id: session_id, decoded: decoded}}
    end
  end

  defp print_summary(summary, opts) do
    IO.puts("Success on #{Telegram.format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Result: #{format_decoded(summary.decoded)}")

    if Keyword.get(opts, :verbose, false) do
      IO.puts(inspect(summary.decoded, pretty: true, limit: :infinity))
    end
  end

  defp format_decoded(%Decoded{
         tl_name: "nearestDc",
         fields: %{country: country, this_dc: this_dc, nearest_dc: nearest_dc}
       }) do
    "nearestDc country=#{country} this_dc=#{this_dc} nearest_dc=#{nearest_dc}"
  end

  defp format_decoded(%Decoded{tl_name: tl_name}), do: tl_name
end
