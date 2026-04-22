defmodule Mix.Tasks.Tl.Generate do
  use Mix.Task

  @shortdoc "Generate Elixir modules from vendored TL schemas"

  @moduledoc """
  Generates Elixir source files under `lib/mtproto/tl/generated`.

      mix tl.generate
      mix tl.generate telegram_api
      mix tl.generate mtproto_api telegram_api
  """

  alias MTProto.TL.Codegen

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    schema_names =
      case args do
        [] -> Codegen.available_schema_names()
        names -> Enum.map(names, &normalize_schema_name/1)
      end

    schema_names
    |> Enum.map(&Codegen.generate_schema!/1)
    |> Enum.each(fn path ->
      Mix.shell().info("generated #{Path.relative_to_cwd(path)}")
    end)
  end

  defp normalize_schema_name(name) do
    name
    |> String.trim()
    |> String.trim_trailing(".tl")
    |> String.to_atom()
  end
end
