defmodule MTProto.TL.VendoredSchema do
  @moduledoc """
  Compile-time-normalized Telegram TL schema snapshots.

  The snapshot files under `priv/tl/*.exs` are evaluated and fully normalized
  at compile time via `@external_resource`, so the decoder only has to read a
  pre-built `%MTProto.TL.Schema.Schema{}` at runtime. The snapshot shape on
  disk mirrors Telegram's official schema JSON:

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

  build_line = fn entry ->
    id =
      entry["id"]
      |> String.to_integer()
      |> Integer.mod(@u32_modulus)
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(8, "0")

    name = entry["predicate"] || Map.fetch!(entry, "method")

    params =
      case Map.fetch!(entry, "params") do
        [] ->
          ""

        ps when is_list(ps) ->
          [
            " ",
            Enum.map_join(ps, " ", fn p ->
              "#{Map.fetch!(p, "name")}:#{Map.fetch!(p, "type")}"
            end)
          ]
      end

    IO.iodata_to_binary([
      name,
      "#",
      id,
      params,
      " = ",
      Map.fetch!(entry, "type"),
      ";"
    ])
  end

  build_schema = fn schema_name, raw ->
    %{"constructors" => constructors} = raw

    definitions =
      Enum.map(constructors, fn entry ->
        line = build_line.(entry)
        {:ok, definition} = Parser.parse_definition(line, section: nil)
        definition
      end)

    Normalize.normalize(%AST.Schema{items: definitions}, name: schema_name)
  end

  @schemas (for {name, path} <- @schema_files, into: %{} do
              {raw, _bindings} = Code.eval_file(path)
              {name, build_schema.(name, raw)}
            end)

  @spec available?(atom()) :: boolean()
  def available?(schema_name), do: Map.has_key?(@schemas, schema_name)

  @spec load(atom()) :: {:ok, NormalizedSchema.t()} | {:error, term()}
  def load(schema_name) do
    case Map.fetch(@schemas, schema_name) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, {:unknown_schema, schema_name}}
    end
  end
end
