defmodule MTProto.TL.VendoredSchema.Builder do
  @moduledoc false

  alias MTProto.TL.Schema.Definition
  alias MTProto.TL.Schema.Generic
  alias MTProto.TL.Schema.Param
  alias MTProto.TL.Schema.Schema, as: NormalizedSchema
  alias MTProto.TL.Schema.TypeExpr

  @u32_modulus 4_294_967_296

  @bare_builtins MapSet.new(
                   ~w(int int32 int53 int64 int128 int256 long double string bytes true)
                 )
  @vector_names MapSet.new(~w(vector Vector))
  @type_token_regex ~r/\s+|[A-Za-z_][A-Za-z0-9_.]*|\d+|[#?!<>\[\]*%]/

  @spec build_schema(atom(), map(), map()) :: NormalizedSchema.t()
  def build_schema(schema_name, raw, generics_by_name) do
    definitions =
      normalize_entries(
        Map.get(raw, "constructors", []),
        schema_name,
        :constructor,
        generics_by_name
      ) ++
        normalize_entries(
          Map.get(raw, "methods", []),
          schema_name,
          :function,
          generics_by_name
        )

    %NormalizedSchema{name: schema_name, definitions: definitions}
  end

  defp normalize_entries(entries, schema_name, kind, generics_by_name) do
    Enum.map(entries, fn entry ->
      tl_name = entry["predicate"] || Map.fetch!(entry, "method")
      generic_names = Map.get(generics_by_name, tl_name, [])
      generic_name_set = MapSet.new(generic_names)

      %Definition{
        schema: schema_name,
        kind: kind,
        tl_name: tl_name,
        id: normalize_id(entry["id"]),
        generics: Enum.map(generic_names, &generic/1),
        params:
          Enum.map(Map.get(entry, "params", []), fn param ->
            %Param{
              field: normalize_field_name(param["name"]),
              tl_name: param["name"],
              type: parse_type!(param["type"], generic_name_set)
            }
          end),
        result_type: parse_type!(Map.fetch!(entry, "type"), generic_name_set),
        line: nil
      }
    end)
  end

  defp generic(name) do
    %Generic{
      name: name,
      kind: ref("Type", MapSet.new())
    }
  end

  defp normalize_id(nil), do: nil

  defp normalize_id(id) when is_integer(id) do
    Integer.mod(id, @u32_modulus)
  end

  defp normalize_id(id) when is_binary(id) do
    id
    |> String.to_integer()
    |> normalize_id()
  end

  defp normalize_field_name(nil), do: nil
  defp normalize_field_name(name), do: String.to_atom(name)

  defp parse_type!(type, generic_names) when is_binary(type) do
    tokens = tokenize!(type)

    case parse_expr(tokens, generic_names) do
      {:ok, expr, []} ->
        expr

      {:ok, _expr, rest} ->
        raise ArgumentError,
              "unexpected trailing tokens in TL type #{inspect(type)}: #{inspect(rest)}"

      {:error, reason} ->
        raise ArgumentError,
              "could not parse TL type #{inspect(type)}: #{inspect(reason)}"
    end
  end

  defp tokenize!(type) do
    tokens = Regex.scan(@type_token_regex, type) |> List.flatten()

    if Enum.join(tokens) == type do
      Enum.reject(tokens, &String.match?(&1, ~r/^\s+$/))
    else
      raise ArgumentError, "unsupported TL type syntax: #{inspect(type)}"
    end
  end

  defp parse_expr(tokens, generic_names) do
    with {:ok, left, rest} <- parse_repetition(tokens, generic_names) do
      case rest do
        ["?" | rest] ->
          with {:ok, right, rest} <- parse_expr(rest, generic_names) do
            {:ok, conditional(left, right), rest}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_repetition(tokens, generic_names) do
    with {:ok, left, rest} <- parse_prefix(tokens, generic_names) do
      case rest do
        ["*" | rest] ->
          case left do
            %TypeExpr.Number{} = multiplier ->
              with {:ok, right, rest} <- parse_prefix(rest, generic_names) do
                {:ok,
                 %TypeExpr.Repetition{
                   multiplier: multiplier,
                   type: right
                 }, rest}
              end

            _ ->
              {:error, {:invalid_repetition_multiplier, left}}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_prefix(["!" | rest], generic_names) do
    with {:ok, expr, rest} <- parse_prefix(rest, generic_names) do
      {:ok, %TypeExpr.Bang{type: expr}, rest}
    end
  end

  defp parse_prefix(["%" | rest], generic_names) do
    with {:ok, expr, rest} <- parse_prefix(rest, generic_names) do
      {:ok, %TypeExpr.Bare{type: expr}, rest}
    end
  end

  defp parse_prefix(tokens, generic_names),
    do: parse_application(tokens, generic_names)

  defp parse_application(tokens, generic_names) do
    with {:ok, callee, rest} <- parse_atom(tokens, generic_names) do
      parse_application_rest(callee, rest, generic_names)
    end
  end

  defp parse_application_rest(callee, ["<" | rest], generic_names) do
    with {:ok, args, rest} <- parse_angle_args(rest, generic_names, []) do
      parse_application_rest(
        build_application(callee, args, :angle),
        rest,
        generic_names
      )
    end
  end

  defp parse_application_rest(callee, tokens, generic_names) do
    if starts_expr?(tokens) do
      with {:ok, arg, rest} <- parse_prefix(tokens, generic_names) do
        parse_application_rest(
          build_application(callee, [arg], :juxtaposition),
          rest,
          generic_names
        )
      end
    else
      {:ok, callee, tokens}
    end
  end

  defp parse_angle_args([">" | rest], _generic_names, args),
    do: {:ok, Enum.reverse(args), rest}

  defp parse_angle_args(tokens, generic_names, args) do
    with {:ok, arg, rest} <- parse_expr(tokens, generic_names) do
      parse_angle_args(rest, generic_names, [arg | args])
    end
  end

  defp parse_atom(["#" | rest], _generic_names),
    do: {:ok, %TypeExpr.Special{value: "#"}, rest}

  defp parse_atom(["?" | rest], _generic_names),
    do: {:ok, %TypeExpr.Special{value: "?"}, rest}

  defp parse_atom(["[" | rest], generic_names) do
    with {:ok, items, rest} <- parse_group_items(rest, generic_names, []) do
      {:ok, %TypeExpr.Group{delimiter: :square, items: items}, rest}
    end
  end

  defp parse_atom([token | rest], generic_names) do
    cond do
      String.match?(token, ~r/^\d+$/) ->
        {:ok, %TypeExpr.Number{value: String.to_integer(token)}, rest}

      String.match?(token, ~r/^[A-Za-z_][A-Za-z0-9_.]*$/) ->
        {:ok, ref(token, generic_names), rest}

      true ->
        {:error, {:unexpected_token, token}}
    end
  end

  defp parse_atom([], _generic_names), do: {:error, :unexpected_eof}

  defp parse_group_items(["]" | rest], _generic_names, items),
    do: {:ok, Enum.reverse(items), rest}

  defp parse_group_items(tokens, generic_names, items) do
    with {:ok, item, rest} <- parse_expr(tokens, generic_names) do
      parse_group_items(rest, generic_names, [item | items])
    end
  end

  defp build_application(
         %TypeExpr.Ref{name: name, boxing: boxing} = callee,
         [arg],
         syntax
       ) do
    if MapSet.member?(@vector_names, name) do
      %TypeExpr.Vector{item_type: arg, boxing: boxing}
    else
      %TypeExpr.Application{callee: callee, args: [arg], syntax: syntax}
    end
  end

  defp build_application(callee, args, syntax) do
    %TypeExpr.Application{callee: callee, args: args, syntax: syntax}
  end

  defp conditional(%TypeExpr.Ref{name: guard}, type) do
    case Regex.run(~r/^([a-z_][a-zA-Z0-9_]*)\.(\d+)$/, guard) do
      [_, field_name, bit] ->
        %TypeExpr.Flag{
          field: String.to_atom(field_name),
          tl_name: field_name,
          bit: String.to_integer(bit),
          type: type
        }

      _ ->
        %TypeExpr.Conditional{
          guard: %TypeExpr.Ref{
            name: guard,
            segments: String.split(guard, "."),
            kind: :constructor,
            boxing: :bare
          },
          type: type
        }
    end
  end

  defp conditional(guard, type),
    do: %TypeExpr.Conditional{guard: guard, type: type}

  defp ref(name, generic_names) do
    segments = String.split(name, ".")

    cond do
      MapSet.member?(generic_names, name) ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :generic,
          boxing: :dynamic
        }

      MapSet.member?(@bare_builtins, name) ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :builtin,
          boxing: :bare
        }

      boxed_reference?(name) ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :type,
          boxing: :boxed
        }

      true ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :constructor,
          boxing: :bare
        }
    end
  end

  defp boxed_reference?(name) do
    name
    |> String.split(".")
    |> List.last()
    |> String.match?(~r/^[A-Z]/)
  end

  defp starts_expr?([token | _]) when token in [">", "]", "?", "*"],
    do: false

  defp starts_expr?([token | _]) do
    String.match?(token, ~r/^\d+$/) or
      String.match?(token, ~r/^[A-Za-z_][A-Za-z0-9_.]*$/) or
      token in ["#", "!", "%", "["]
  end

  defp starts_expr?([]), do: false
end

defmodule MTProto.TL.VendoredSchema do
  @moduledoc """
  Compile-time-normalized vendored TL schema snapshots.

  The snapshot files under `priv/tl/*.exs` are evaluated and normalized at
  compile time, so the decoder and request encoder only have to load a
  pre-built `%MTProto.TL.Schema.Schema{}` at runtime.
  """

  alias MTProto.TL.Schema.Schema, as: NormalizedSchema
  alias MTProto.TL.VendoredSchema.Builder

  @schema_files %{
    mtproto_api: Path.expand("../../../priv/tl/mtproto_api.exs", __DIR__),
    telegram_api: Path.expand("../../../priv/tl/telegram_api.exs", __DIR__)
  }

  @schema_generics %{
    mtproto_api: %{
      "vector" => ["t"]
    },
    telegram_api: %{
      "vector" => ["t"],
      "invokeAfterMsg" => ["X"],
      "invokeAfterMsgs" => ["X"],
      "initConnection" => ["X"],
      "invokeWithLayer" => ["X"],
      "invokeWithoutUpdates" => ["X"],
      "invokeWithMessagesRange" => ["X"],
      "invokeWithTakeout" => ["X"],
      "invokeWithBusinessConnection" => ["X"],
      "invokeWithGooglePlayIntegrity" => ["X"],
      "invokeWithApnsSecret" => ["X"],
      "invokeWithReCaptcha" => ["X"]
    }
  }

  for {_name, snapshot_path} <- @schema_files do
    @external_resource snapshot_path
  end

  @schemas (for {name, snapshot_path} <- @schema_files, into: %{} do
              {raw, _bindings} = Code.eval_file(snapshot_path)
              generics_by_name = Map.get(@schema_generics, name, %{})
              {name, Builder.build_schema(name, raw, generics_by_name)}
            end)

  @spec available?(atom()) :: boolean()
  def available?(schema_name), do: Map.has_key?(@schemas, schema_name)

  @spec available_schemas() :: [atom()]
  def available_schemas, do: Map.keys(@schemas)

  @spec load(atom()) :: {:ok, NormalizedSchema.t()} | {:error, term()}
  def load(schema_name) do
    case Map.fetch(@schemas, schema_name) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, {:unknown_schema, schema_name}}
    end
  end
end
