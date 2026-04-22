defmodule Exmt.CLI.Commands.GetConfig do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["get-config"]

  @impl true
  def aliases, do: [["get_config"]]

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
    Telegram.run_command(fn ->
      with {:ok, opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(context, &get_config(&1, &2, context)) do
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

  defp get_config(client, endpoint, context) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.get_config_sync(
             client,
             Telegram.request_opts(context, request: :help_get_config)
           ) do
      {:ok, %{endpoint: endpoint, session_id: session_id, decoded: decoded}}
    end
  end

  defp print_summary(summary, opts) do
    IO.puts("Success on #{Telegram.format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Result: #{format_decoded(summary.decoded)}")

    if Keyword.get(opts, :verbose, false) do
      IO.puts("Decoded:")
      IO.puts(inspect(summary.decoded, pretty: true, limit: :infinity))
    end
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

  defp hex32(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
