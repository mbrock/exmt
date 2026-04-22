defmodule Exmt.CLI.Commands.Auth.SignIn do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.TL.Runtime.Decoded
  alias MTProto.Telegram.Client, as: TelegramClient

  @impl true
  def command_path, do: ["auth", "sign-in"]

  @impl true
  def aliases, do: [["auth", "sign_in"]]

  @impl true
  def summary, do: "Perform auth.signIn using a phone code hash and code"

  @impl true
  def usage do
    """
    usage:
      exmt auth sign-in <phone-number> <phone-code-hash> <phone-code>
      exmt auth sign-in +15551234567 hash-from-send-code 12345 --session-file .exmt/demo.term

    environment:
      TDLIB_API_ID or TELEGRAM_API_ID
    """
  end

  @impl true
  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts, phone_number, phone_code_hash, phone_code} <-
             parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(
               context,
               &sign_in(
                 &1,
                 &2,
                 context,
                 phone_number,
                 phone_code_hash,
                 phone_code
               )
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

      length(rest) < 3 ->
        {:error,
         {:missing_argument, "<phone-number> <phone-code-hash> <phone-code>"}}

      length(rest) > 3 ->
        {:error, {:unexpected_arguments, Enum.drop(rest, 3)}}

      true ->
        [phone_number, phone_code_hash, phone_code] = rest
        {:ok, opts, phone_number, phone_code_hash, phone_code}
    end
  end

  defp sign_in(
         client,
         endpoint,
         context,
         phone_number,
         phone_code_hash,
         phone_code
       ) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.sign_in_sync(
             client,
             phone_number,
             phone_code_hash,
             phone_code,
             Telegram.request_opts(context, request: :auth_sign_in)
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
         tl_name: "auth.authorization",
         constructor_id: constructor_id,
         fields: %{user: user}
       }) do
    "auth.authorization##{hex32(constructor_id)} user=#{format_user(user)}"
  end

  defp format_decoded(%Decoded{
         tl_name: tl_name,
         constructor_id: constructor_id
       }) do
    "#{tl_name}##{hex32(constructor_id)}"
  end

  defp format_user(%Decoded{tl_name: tl_name, fields: fields}) do
    user_id = Map.get(fields, :id)
    username = Map.get(fields, :username)

    [tl_name, maybe_user_id(user_id), maybe_username(username)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_user(user), do: inspect(user)

  defp maybe_user_id(nil), do: nil
  defp maybe_user_id(user_id), do: "id=#{user_id}"

  defp maybe_username(nil), do: nil
  defp maybe_username(username), do: "username=#{inspect(username)}"

  defp hex32(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
