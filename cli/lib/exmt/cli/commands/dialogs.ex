defmodule Exmt.CLI.Commands.Dialogs do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["dialogs"]

  @impl true
  def aliases, do: []

  @impl true
  def summary, do: "Fetch messages.getDialogs"

  @impl true
  def usage do
    """
    usage:
      exmt dialogs
      exmt dialogs --limit 50 --exclude-pinned --folder-id 1
    """
  end

  @impl true
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts, query_opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(
               context,
               &dialogs(&1, &2, context, query_opts)
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
      OptionParser.parse(argv,
        strict:
          Telegram.common_switches() ++
            [limit: :integer, exclude_pinned: :boolean, folder_id: :integer]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest != [] ->
        {:error, {:unexpected_arguments, rest}}

      true ->
        query_opts =
          opts
          |> Keyword.take([:limit, :exclude_pinned, :folder_id])

        {:ok, opts, query_opts}
    end
  end

  defp dialogs(client, endpoint, context, query_opts) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.messages_get_dialogs_sync(
             client,
             Telegram.request_opts(
               context,
               Keyword.merge(query_opts, request: :messages_get_dialogs)
             )
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

  defp format_decoded(%Decoded{tl_name: tl_name, fields: fields}) do
    dialogs = fields |> Map.get(:dialogs, []) |> length()
    messages = fields |> Map.get(:messages, []) |> length()
    chats = fields |> Map.get(:chats, []) |> length()
    users = fields |> Map.get(:users, []) |> length()

    "#{tl_name} dialogs=#{dialogs} messages=#{messages} chats=#{chats} users=#{users}"
  end

  defp format_decoded(%Decoded{tl_name: tl_name}), do: tl_name
end
