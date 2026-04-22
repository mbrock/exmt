defmodule Exmt.CLI.Commands.SendMessage do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["send-message"]

  @impl true
  def aliases, do: [["send_message"]]

  @impl true
  def summary, do: "Send a text message with messages.sendMessage"

  @impl true
  def usage do
    """
    usage:
      exmt send-message --peer self "hello from exmt"
      exmt send-message --peer user:123456789:987654321 --silent "hi"
    """
  end

  @impl true
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts, message, query_opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(
               context,
               &send_message(&1, &2, context, message, query_opts)
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
              random_id: :integer,
              silent: :boolean,
              no_webpage: :boolean
            ]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest == [] ->
        {:error, {:missing_argument, "<message>"}}

      length(rest) > 1 ->
        {:error, {:unexpected_arguments, Enum.drop(rest, 1)}}

      true ->
        with {:ok, peer} <- parse_peer_opt(opts) do
          query_opts =
            opts
            |> Keyword.take([:silent, :no_webpage, :random_id])
            |> Keyword.put(:peer, peer)
            |> ensure_random_id()

          {:ok, opts, hd(rest), query_opts}
        end
    end
  end

  defp parse_peer_opt(opts) do
    opts
    |> Keyword.get(:peer, "self")
    |> Telegram.parse_peer()
  end

  defp ensure_random_id(query_opts) do
    Keyword.put_new_lazy(query_opts, :random_id, fn ->
      System.unique_integer([:positive, :monotonic])
    end)
  end

  defp send_message(client, endpoint, context, message, query_opts) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.messages_send_message_sync(
             client,
             message,
             Telegram.request_opts(
               context,
               Keyword.merge(query_opts, request: :messages_send_message)
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
    updates = fields |> Map.get(:updates, []) |> length()
    users = fields |> Map.get(:users, []) |> length()
    chats = fields |> Map.get(:chats, []) |> length()
    "#{tl_name} updates=#{updates} users=#{users} chats=#{chats}"
  end

  defp format_decoded(%Decoded{tl_name: tl_name}), do: tl_name
end
