defmodule MTProto.TL.VendoredSchema do
  @moduledoc """
  Loads vendored Telegram TL schema definitions from Elixir term snapshots.

  The snapshot files under `priv/tl/*.exs` are evaluated at compile time via
  `@external_resource`, so the decoder has no runtime JSON dependency. The
  snapshot shape mirrors Telegram's official schema JSON:

      %{"constructors" => [%{"id" => ..., "predicate" => ..., "params" => [...], "type" => ...}, ...]}

  Refresh the snapshot with `mix tl.fetch_telegram_schema`.
  """

  alias MTProto.TL.AST
  alias MTProto.TL.{Normalize, Parser}
  alias MTProto.TL.Schema.Schema, as: NormalizedSchema

  @u32_modulus 4_294_967_296

  @schema_files %{
    telegram_api: Path.expand("../../../priv/tl/telegram_api.exs", __DIR__)
  }

  for {_name, path} <- @schema_files do
    @external_resource path
  end

  @schemas (for {name, path} <- @schema_files, into: %{} do
              {term, _bindings} = Code.eval_file(path)
              {name, term}
            end)

  @spec available?(atom()) :: boolean()
  def available?(schema_name), do: Map.has_key?(@schemas, schema_name)

  @spec load(atom()) :: {:ok, NormalizedSchema.t()} | {:error, term()}
  def load(schema_name) do
    with {:ok, %{"constructors" => constructors}} <- fetch_schema(schema_name),
         {:ok, definitions} <- load_entries(constructors, :constructor, []) do
      {:ok,
       Normalize.normalize(
         %AST.Schema{items: definitions},
         name: schema_name
       )}
    end
  end

  defp fetch_schema(schema_name) do
    case Map.fetch(@schemas, schema_name) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, {:unknown_schema, schema_name}}
    end
  end

  defp load_entries([], _kind, definitions) do
    {:ok, Enum.reverse(definitions)}
  end

  defp load_entries([entry | rest], kind, definitions) do
    with {:ok, definition} <- entry_to_definition(entry, kind) do
      load_entries(rest, kind, [definition | definitions])
    end
  end

  defp entry_to_definition(entry, kind) when is_map(entry) do
    line = definition_line(entry)
    section = if kind == :function, do: :functions, else: nil

    case Parser.parse_definition(line, section: section) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, error} ->
        {:error, {:invalid_schema_entry, kind, line, error}}
    end
  end

  defp definition_line(entry) do
    [
      definition_name(entry),
      "#",
      constructor_hex(entry),
      params(entry),
      " = ",
      Map.fetch!(entry, "type"),
      ";"
    ]
    |> IO.iodata_to_binary()
  end

  defp definition_name(entry) do
    Map.get(entry, "predicate") || Map.fetch!(entry, "method")
  end

  defp constructor_hex(%{"id" => id}) when is_binary(id) do
    id
    |> String.to_integer()
    |> Integer.mod(@u32_modulus)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp params(%{"params" => []}), do: ""

  defp params(%{"params" => params}) when is_list(params) do
    [
      " ",
      Enum.map_join(params, " ", fn param ->
        "#{Map.fetch!(param, "name")}:#{Map.fetch!(param, "type")}"
      end)
    ]
  end
end
