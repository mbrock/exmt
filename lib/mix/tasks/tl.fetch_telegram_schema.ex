defmodule Mix.Tasks.Tl.FetchTelegramSchema do
  use Mix.Task

  @compile {:no_warn_undefined, [{:httpc, :request, 4}, {JSON, :decode, 1}]}

  @shortdoc "Fetch the official Telegram schema snapshot as an Elixir term"

  @moduledoc """
  Fetches the official Telegram schema JSON snapshot and writes it to
  `priv/tl/telegram_api.exs` as a pretty-printed Elixir term.

      mix tl.fetch_telegram_schema
      mix tl.fetch_telegram_schema --url https://core.telegram.org/schema/json
  """

  @default_url "https://core.telegram.org/schema/json"
  @default_output "priv/tl/telegram_api.exs"

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
             {:ok, schema} <- JSON.decode(body),
             :ok <- File.mkdir_p(Path.dirname(output)),
             :ok <- File.write(output, format(schema)) do
          Mix.shell().info("wrote #{Path.relative_to_cwd(output)}")
        else
          {:ok, {{_version, status, reason}, _headers, _body}} ->
            Mix.raise("fetch failed: HTTP #{status} #{inspect(reason)}")

          {:error, reason} ->
            Mix.raise("fetch failed: #{inspect(reason)}")
        end
    end
  end

  defp format(schema) do
    inspect(schema,
      limit: :infinity,
      printable_limit: :infinity,
      pretty: true,
      width: 120
    ) <> "\n"
  end
end
