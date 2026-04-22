defmodule MTProto.TL.JSONSchema do
  @moduledoc """
  Loads Telegram TL schema definitions from the official JSON schema snapshot.

  The runtime decoder only needs normalized constructor metadata, and Telegram's
  official JSON schema already contains constructor IDs, params, and result
  types. This module converts that JSON into the same normalized schema IR used
  by the TL-file path, so the decoder can stay unchanged.
  """

  alias MTProto.TL.AST
  alias MTProto.TL.{Normalize, Parser}
  alias MTProto.TL.Schema.Schema, as: NormalizedSchema

  @u32_modulus 4_294_967_296

  @spec load_file(Path.t(), keyword()) ::
          {:ok, NormalizedSchema.t()} | {:error, term()}
  def load_file(path, opts) do
    schema_name = Keyword.fetch!(opts, :name)

    with {:ok, json} <- File.read(path),
         {:ok, %{"constructors" => constructors}} <- JSON.decode(json),
         {:ok, definitions} <-
           load_entries(constructors, :constructor, []) do
      {:ok,
       Normalize.normalize(
         %AST.Schema{items: definitions},
         name: schema_name
       )}
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
        {:error, {:invalid_json_schema_entry, kind, line, error}}
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
