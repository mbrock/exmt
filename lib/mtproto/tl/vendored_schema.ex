defmodule MTProto.TL.VendoredSchema do
  @moduledoc """
  Compile-time-normalized Telegram TL schema snapshots.

  The snapshot files under `priv/tl/*.exs` are evaluated and fully normalized
  at compile time via `@external_resource`, so the decoder only has to read a
  pre-built `%MTProto.TL.Schema.Schema{}` at runtime. Generic declarations are
  recovered from the vendored `.tl` source so wrapper methods such as
  `invokeWithLayer` retain their `X` type parameter information.
  """

  alias MTProto.TL.AST
  alias MTProto.TL.AST.Definition, as: ASTDefinition
  alias MTProto.TL.AST.Expr
  alias MTProto.TL.Normalize
  alias MTProto.TL.Parser
  alias MTProto.TL.Schema.Schema, as: NormalizedSchema

  @u32_modulus 4_294_967_296

  @schema_files %{
    telegram_api: %{
      snapshot: Path.expand("../../../priv/tl/telegram_api.exs", __DIR__),
      source: Path.expand("../../../priv/tl/telegram_api.tl", __DIR__)
    }
  }

  for {_name, %{snapshot: snapshot_path, source: source_path}} <-
        @schema_files do
    @external_resource snapshot_path
    @external_resource source_path
  end

  render_expr = fn render_expr, expr ->
    case expr do
      %Expr.Reference{name: name} ->
        name

      %Expr.Number{value: value} ->
        Integer.to_string(value)

      %Expr.Special{value: value} ->
        value

      %Expr.Prefix{operator: operator, expr: inner_expr} ->
        Atom.to_string(operator) <> render_expr.(render_expr, inner_expr)

      %Expr.Application{callee: callee, args: args, syntax: :angle} ->
        render_expr.(render_expr, callee) <>
          "<" <>
          Enum.map_join(args, " ", fn arg ->
            render_expr.(render_expr, arg)
          end) <>
          ">"

      %Expr.Application{callee: callee, args: args, syntax: :juxtaposition} ->
        [
          render_expr.(render_expr, callee)
          | Enum.map(args, &render_expr.(render_expr, &1))
        ]
        |> Enum.join(" ")

      %Expr.Group{delimiter: :square, items: items} ->
        "[ " <>
          Enum.map_join(items, " ", fn item ->
            render_expr.(render_expr, item)
          end) <>
          " ]"

      %Expr.Repetition{multiplier: multiplier, expr: repeated_expr} ->
        render_expr.(render_expr, multiplier) <>
          "*" <> render_expr.(render_expr, repeated_expr)

      %Expr.Conditional{guard: guard, expr: conditional_expr} ->
        render_expr.(render_expr, guard) <>
          "?" <> render_expr.(render_expr, conditional_expr)
    end
  end

  build_line = fn entry, generics_by_name ->
    id =
      entry["id"]
      |> String.to_integer()
      |> Integer.mod(@u32_modulus)
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(8, "0")

    name = entry["predicate"] || Map.fetch!(entry, "method")

    generics =
      case Map.get(generics_by_name, name, []) do
        [] ->
          ""

        definitions ->
          [
            " ",
            Enum.map_join(definitions, " ", fn %AST.Generic{
                                                 name: generic_name,
                                                 kind: kind
                                               } ->
              "{#{generic_name}:#{render_expr.(render_expr, kind)}}"
            end)
          ]
      end

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
      generics,
      params,
      " = ",
      Map.fetch!(entry, "type"),
      ";"
    ])
  end

  build_schema = fn schema_name, raw, source_path ->
    {:ok, parsed_schema} = Parser.parse_file(source_path)

    generics_by_name =
      parsed_schema
      |> AST.definitions()
      |> Map.new(fn %ASTDefinition{name: name, generics: generics} ->
        {name, generics}
      end)

    constructors = Map.get(raw, "constructors", [])
    methods = Map.get(raw, "methods", [])

    definitions =
      Enum.map(constructors, fn entry ->
        line = build_line.(entry, generics_by_name)
        {:ok, definition} = Parser.parse_definition(line, section: nil)
        definition
      end) ++
        Enum.map(methods, fn entry ->
          line = build_line.(entry, generics_by_name)

          {:ok, definition} =
            Parser.parse_definition(line, section: :functions)

          definition
        end)

    Normalize.normalize(%AST.Schema{items: definitions}, name: schema_name)
  end

  @schemas (for {name, %{snapshot: snapshot_path, source: source_path}} <-
                  @schema_files,
                into: %{} do
              {raw, _bindings} = Code.eval_file(snapshot_path)
              {name, build_schema.(name, raw, source_path)}
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
