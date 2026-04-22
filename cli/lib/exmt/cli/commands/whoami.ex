defmodule Exmt.CLI.Commands.Whoami do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.Client, as: TelegramClient
  alias MTProto.TL.Runtime.Decoded

  @impl true
  def command_path, do: ["whoami"]

  @impl true
  def aliases, do: [["me"]]

  @impl true
  def summary, do: "Fetch the current logged-in Telegram user"

  @impl true
  def usage do
    """
    usage:
      exmt whoami
      exmt whoami --session-file .exmt/session.term --timeout 60000 --verbose
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
             Telegram.try_endpoints(context, &whoami(&1, &2, context)) do
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

  defp whoami(client, endpoint, context) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, decoded} <-
           TelegramClient.whoami_sync(
             client,
             Telegram.request_opts(context, request: :users_get_self)
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

  defp format_decoded(
         %Decoded{
           tl_name: "users.userFull",
           constructor_id: constructor_id
         } = decoded
       ) do
    current_user = current_user(decoded)

    "users.userFull##{hex32(constructor_id)} user=#{format_user(current_user)}"
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

  defp current_user(%Decoded{
         fields: %{
           full_user: %Decoded{fields: %{id: user_id}},
           users: users
         }
       })
       when is_list(users) do
    Enum.find(users, fn
      %Decoded{fields: %{id: ^user_id}} -> true
      _ -> false
    end)
  end

  defp current_user(_decoded), do: nil

  defp format_user(%Decoded{tl_name: tl_name, fields: fields}) do
    user_id = Map.get(fields, :id)
    username = Map.get(fields, :username)

    [tl_name, maybe_user_id(user_id), maybe_username(username)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_user(nil), do: "unknown"
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
