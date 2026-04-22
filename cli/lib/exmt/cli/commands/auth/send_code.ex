defmodule Exmt.CLI.Commands.Auth.SendCode do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["auth", "send-code"]

  @impl true
  def aliases, do: [["auth", "send_code"]]

  @impl true
  def summary, do: "Perform auth.sendCode for a phone number"

  @impl true
  def usage do
    """
    usage:
      exmt auth send-code <phone-number>
      exmt auth send-code +15551234567 --session-file .exmt/demo.term --timeout 60000

    environment:
      TDLIB_API_ID or TELEGRAM_API_ID
      TDLIB_API_HASH or TELEGRAM_API_HASH
    """
  end

  @impl true
  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts, phone_number} <- parse_args(argv),
           {:ok, context} <-
             Telegram.build_context(opts, require: [:api_id, :api_hash]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(
               context,
               &send_code(&1, &2, context, phone_number)
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
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest == [] ->
        {:error, {:missing_argument, "<phone-number>"}}

      length(rest) > 1 ->
        {:error, {:unexpected_arguments, Enum.drop(rest, 1)}}

      true ->
        {:ok, opts, hd(rest)}
    end
  end

  defp send_code(client, endpoint, context, phone_number) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.send_code_sync(
             client,
             phone_number,
             context.api_hash,
             Telegram.request_opts(context, request: :auth_send_code)
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
         tl_name: "auth.sentCode",
         constructor_id: constructor_id,
         fields: fields
       }) do
    type = format_sent_code_type(fields.type)
    next_type = format_optional_sent_code_type(fields.next_type)
    timeout = format_optional_timeout(fields.timeout)

    [
      "auth.sentCode##{hex32(constructor_id)}",
      "phone_code_hash=#{inspect(fields.phone_code_hash)}",
      "type=#{type}",
      next_type,
      timeout
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_decoded(%Decoded{
         tl_name: tl_name,
         constructor_id: constructor_id
       }) do
    "#{tl_name}##{hex32(constructor_id)}"
  end

  defp format_sent_code_type(%Decoded{
         tl_name: tl_name,
         fields: %{length: length}
       }) do
    "#{tl_name}(length=#{length})"
  end

  defp format_sent_code_type(%Decoded{tl_name: tl_name}), do: tl_name
  defp format_sent_code_type(type), do: inspect(type)

  defp format_optional_sent_code_type(nil), do: nil

  defp format_optional_sent_code_type(type),
    do: "next_type=#{format_sent_code_type(type)}"

  defp format_optional_timeout(nil), do: nil
  defp format_optional_timeout(timeout), do: "timeout=#{timeout}"

  defp hex32(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
