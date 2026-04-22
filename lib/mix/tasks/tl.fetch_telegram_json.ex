defmodule Mix.Tasks.Tl.FetchTelegramJson do
  use Mix.Task

  @compile {:no_warn_undefined, {:httpc, :request, 4}}

  @shortdoc "Fetch the official Telegram schema JSON snapshot"

  @moduledoc """
  Fetches the official Telegram schema JSON snapshot into `priv/tl`.

      mix tl.fetch_telegram_json
      mix tl.fetch_telegram_json --url https://core.telegram.org/schema/json
  """

  @default_url "https://core.telegram.org/schema/json"
  @default_output "priv/tl/telegram_api.json"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [url: :string, output: :string])

    cond do
      invalid != [] ->
        Mix.raise("invalid switches: #{inspect(invalid)}")

      rest != [] ->
        Mix.raise("unexpected arguments: #{inspect(rest)}")

      true ->
        url = Keyword.get(opts, :url, @default_url)
        output = Keyword.get(opts, :output, @default_output)

        Mix.shell().info("fetching #{url}")

        with {:ok, _apps} <- Application.ensure_all_started(:inets),
             {:ok, _apps} <- Application.ensure_all_started(:ssl),
             {:ok, {{_version, 200, _reason}, _headers, body}} <-
               :httpc.request(:get, {String.to_charlist(url), []}, [],
                 body_format: :binary
               ),
             :ok <- File.mkdir_p(Path.dirname(output)),
             :ok <- File.write(output, body) do
          Mix.shell().info("wrote #{Path.relative_to_cwd(output)}")
        else
          {:ok, {{_version, status, reason}, _headers, _body}} ->
            Mix.raise("fetch failed: HTTP #{status} #{inspect(reason)}")

          {:error, reason} ->
            Mix.raise("fetch failed: #{inspect(reason)}")
        end
    end
  end
end
