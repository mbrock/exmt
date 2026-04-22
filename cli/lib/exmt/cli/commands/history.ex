defmodule Exmt.CLI.Commands.History do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["history"]

  @impl true
  def aliases, do: []

  @impl true
  def summary, do: "Fetch messages.getHistory for a peer"

  @impl true
  def usage do
    """
    usage:
      exmt history --peer self
      exmt history --peer user:123456789:987654321 --limit 20 --offset-id 0
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
               &history(&1, &2, context, query_opts)
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
            [
              peer: :string,
              limit: :integer,
              offset_id: :integer,
              offset_date: :integer,
              add_offset: :integer,
              max_id: :integer,
              min_id: :integer
            ]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest != [] ->
        {:error, {:unexpected_arguments, rest}}

      true ->
        with {:ok, peer} <- parse_peer_opt(opts) do
          query_opts =
            opts
            |> Keyword.take([
              :limit,
              :offset_id,
              :offset_date,
              :add_offset,
              :max_id,
              :min_id
            ])
            |> Keyword.put(:peer, peer)

          {:ok, opts, query_opts}
        end
    end
  end

  defp parse_peer_opt(opts) do
    opts
    |> Keyword.get(:peer, "self")
    |> Telegram.parse_peer()
  end

  defp history(client, endpoint, context, query_opts) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.messages_get_history_sync(
             client,
             Telegram.request_opts(
               context,
               Keyword.merge(query_opts, request: :messages_get_history)
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
    messages = fields |> Map.get(:messages, []) |> length()
    chats = fields |> Map.get(:chats, []) |> length()
    users = fields |> Map.get(:users, []) |> length()
    "#{tl_name} messages=#{messages} chats=#{chats} users=#{users}"
  end

  defp format_decoded(%Decoded{tl_name: tl_name}), do: tl_name
end
