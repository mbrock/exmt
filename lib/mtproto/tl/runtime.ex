defmodule MTProto.TL.Runtime do
  @moduledoc """
  Runtime schema-driven TL decoder backed by the vendored Telegram schemas.
  """

  import Bitwise

  alias MTProto.TL
  alias MTProto.TL.JSONSchema
  alias MTProto.TL.{Normalize, Parser}
  alias MTProto.TL.Schema.Definition
  alias MTProto.TL.Schema.Param
  alias MTProto.TL.Schema.TypeExpr

  @default_schema_names [:mtproto_api, :telegram_api]
  @schemas_dir Path.expand("priv/tl", File.cwd!())

  defmodule Decoded do
    @moduledoc false

    defstruct [:schema, :tl_name, :type_name, :constructor_id, fields: %{}]

    @type t :: %__MODULE__{
            schema: atom(),
            tl_name: binary(),
            type_name: binary() | nil,
            constructor_id: non_neg_integer(),
            fields: map()
          }
  end

  @type decoded_value ::
          Decoded.t() | boolean() | integer() | float() | binary() | [term()]

  @spec decode(binary(), keyword()) ::
          {:ok, decoded_value(), binary()} | {:error, term()}
  def decode(binary, opts \\ []) when is_binary(binary) do
    registry =
      registry(Keyword.get(opts, :schema_names, @default_schema_names))

    case Keyword.fetch(opts, :type) do
      {:ok, type_name} ->
        decode_boxed(binary, registry, normalize_type_name(type_name))

      :error ->
        decode_boxed(binary, registry, nil)
    end
  end

  @spec decode!(binary(), keyword()) :: {decoded_value(), binary()}
  def decode!(binary, opts \\ []) do
    case decode(binary, opts) do
      {:ok, decoded, rest} ->
        {decoded, rest}

      {:error, reason} ->
        raise ArgumentError, "TL decode failed: #{inspect(reason)}"
    end
  end

  defp decode_boxed(
         <<constructor_id::little-unsigned-32, rest::binary>>,
         registry,
         expected_type_name
       ) do
    case Map.get(registry.by_id, constructor_id) do
      nil ->
        {:error, {:unknown_constructor, constructor_id}}

      definition ->
        with :ok <- validate_expected_type(definition, expected_type_name) do
          decode_definition(definition, rest, registry)
        end
    end
  end

  defp decode_boxed(_binary, _registry, _expected_type_name),
    do: {:error, :short_constructor}

  defp decode_definition(
         %Definition{
           tl_name: "boolTrue",
           result_type: %TypeExpr.Ref{name: "Bool"}
         } = _definition,
         binary,
         _registry
       ) do
    {:ok, true, binary}
  end

  defp decode_definition(
         %Definition{
           tl_name: "boolFalse",
           result_type: %TypeExpr.Ref{name: "Bool"}
         } = _definition,
         binary,
         _registry
       ) do
    {:ok, false, binary}
  end

  defp decode_definition(%Definition{} = definition, binary, registry) do
    with {:ok, fields, rest, _flags} <-
           decode_params(definition.params, binary, registry, %{}, %{}) do
      {:ok,
       %Decoded{
         schema: definition.schema,
         tl_name: definition.tl_name,
         type_name: result_type_name(definition),
         constructor_id: definition.id,
         fields: fields
       }, rest}
    end
  end

  defp decode_params([], binary, _registry, fields, flags_state) do
    {:ok, fields, binary, flags_state}
  end

  defp decode_params(
         [%Param{} = param | rest],
         binary,
         registry,
         fields,
         flags_state
       ) do
    case param.type do
      %TypeExpr.Special{value: "#"} ->
        with {:ok, value, binary} <- TL.decode_int(binary) do
          field = field_key(param)

          decode_params(
            rest,
            binary,
            registry,
            Map.put(fields, field, value),
            Map.put(flags_state, field, value)
          )
        end

      %TypeExpr.Flag{field: flags_field, bit: bit, type: inner_type} ->
        present? = flag_set?(Map.get(flags_state, flags_field, 0), bit)
        field = field_key(param)

        with {:ok, value, binary} <-
               decode_flag_value(present?, inner_type, binary, registry) do
          decode_params(
            rest,
            binary,
            registry,
            Map.put(fields, field, value),
            flags_state
          )
        end

      type ->
        with {:ok, value, binary} <- decode_type(type, binary, registry) do
          decode_params(
            rest,
            binary,
            registry,
            Map.put(fields, field_key(param), value),
            flags_state
          )
        end
    end
  end

  defp decode_flag_value(
         false,
         %TypeExpr.Ref{name: "true", kind: :builtin},
         binary,
         _registry
       ),
       do: {:ok, false, binary}

  defp decode_flag_value(false, _type, binary, _registry),
    do: {:ok, nil, binary}

  defp decode_flag_value(
         true,
         %TypeExpr.Ref{name: "true", kind: :builtin},
         binary,
         _registry
       ),
       do: {:ok, true, binary}

  defp decode_flag_value(true, type, binary, registry),
    do: decode_type(type, binary, registry)

  defp decode_type(%TypeExpr.Bang{type: type}, binary, registry),
    do: decode_type(type, binary, registry)

  defp decode_type(%TypeExpr.Bare{type: type}, binary, registry),
    do: decode_type(type, binary, registry)

  defp decode_type(
         %TypeExpr.Vector{item_type: item_type, boxing: :boxed},
         binary,
         registry
       ) do
    with <<0x15, 0xC4, 0xB5, 0x1C, count::little-unsigned-32, rest::binary>> <-
           binary,
         {:ok, items, rest} <-
           decode_repeated_items(count, item_type, rest, registry, []) do
      {:ok, items, rest}
    else
      _ -> {:error, :invalid_vector}
    end
  end

  defp decode_type(
         %TypeExpr.Vector{item_type: item_type, boxing: :bare},
         binary,
         registry
       ) do
    with {:ok, count, rest} <- TL.decode_int(binary),
         true <- count >= 0,
         {:ok, items, rest} <-
           decode_repeated_items(count, item_type, rest, registry, []) do
      {:ok, items, rest}
    else
      false -> {:error, :invalid_vector}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "int"},
         binary,
         _registry
       ),
       do: TL.decode_int(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "int32"},
         binary,
         _registry
       ),
       do: TL.decode_int(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "int53"},
         binary,
         _registry
       ),
       do: TL.decode_signed_long(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "int64"},
         binary,
         _registry
       ),
       do: TL.decode_signed_long(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "long"},
         binary,
         _registry
       ),
       do: TL.decode_signed_long(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "int128"},
         binary,
         _registry
       ),
       do: TL.decode_int128(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "int256"},
         binary,
         _registry
       ),
       do: TL.decode_int256(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "double"},
         <<value::little-float-64, rest::binary>>,
         _registry
       ),
       do: {:ok, value, rest}

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "double"},
         _binary,
         _registry
       ),
       do: {:error, :short_double}

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "string"},
         binary,
         _registry
       ),
       do: TL.decode_bytes(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "bytes"},
         binary,
         _registry
       ),
       do: TL.decode_bytes(binary)

  defp decode_type(
         %TypeExpr.Ref{kind: :builtin, name: "true"},
         binary,
         _registry
       ),
       do: {:ok, true, binary}

  defp decode_type(
         %TypeExpr.Ref{kind: :type, boxing: :boxed, name: type_name},
         binary,
         registry
       ),
       do: decode_boxed(binary, registry, type_name)

  defp decode_type(
         %TypeExpr.Ref{
           kind: :constructor,
           boxing: :bare,
           name: constructor_name
         },
         binary,
         registry
       ) do
    case Map.get(registry.bare_by_name, constructor_name) do
      nil -> {:error, {:unknown_bare_constructor, constructor_name}}
      definition -> decode_definition(definition, binary, registry)
    end
  end

  defp decode_type(type, _binary, _registry),
    do: {:error, {:unsupported_type, type}}

  defp decode_repeated_items(0, _item_type, binary, _registry, items),
    do: {:ok, Enum.reverse(items), binary}

  defp decode_repeated_items(count, item_type, binary, registry, items)
       when count > 0 do
    with {:ok, item, binary} <- decode_type(item_type, binary, registry) do
      decode_repeated_items(count - 1, item_type, binary, registry, [
        item | items
      ])
    end
  end

  defp field_key(%Param{field: field}) when not is_nil(field), do: field

  defp field_key(%Param{tl_name: tl_name}) when is_binary(tl_name),
    do: String.to_atom(tl_name)

  defp field_key(_param), do: :value

  defp flag_set?(flags_value, bit)
       when is_integer(flags_value) and is_integer(bit) and bit >= 0 do
    (flags_value &&& 1 <<< bit) != 0
  end

  defp validate_expected_type(_definition, nil), do: :ok

  defp validate_expected_type(%Definition{} = definition, expected_type_name) do
    case result_type_name(definition) do
      ^expected_type_name ->
        :ok

      actual ->
        {:error,
         {:unexpected_constructor_type, definition.id, actual,
          expected_type_name}}
    end
  end

  defp result_type_name(%Definition{result_type: %TypeExpr.Ref{name: name}}),
    do: name

  defp result_type_name(%Definition{}), do: nil

  defp normalize_type_name(type_name) when is_atom(type_name),
    do: Atom.to_string(type_name)

  defp normalize_type_name(type_name) when is_binary(type_name), do: type_name

  defp registry(schema_names) do
    persistent_term_key = {__MODULE__, :registry, List.to_tuple(schema_names)}

    case :persistent_term.get(persistent_term_key, :missing) do
      :missing ->
        registry = build_registry(schema_names)
        :persistent_term.put(persistent_term_key, registry)
        registry

      registry ->
        registry
    end
  end

  defp build_registry(schema_names) do
    definitions =
      schema_names
      |> Enum.flat_map(&load_schema_definitions/1)
      |> Enum.filter(&(&1.kind == :constructor))

    %{
      by_id: Map.new(definitions, &{&1.id, &1}),
      bare_by_name:
        definitions
        |> Enum.filter(&bare_constructor?/1)
        |> Map.new(&{&1.tl_name, &1})
    }
  end

  defp load_schema_definitions(schema_name) do
    cond do
      File.exists?(json_schema_path(schema_name)) ->
        {:ok, normalized_schema} =
          JSONSchema.load_file(json_schema_path(schema_name),
            name: schema_name
          )

        normalized_schema.definitions

      true ->
        schema_path = tl_schema_path(schema_name)
        {:ok, parsed_schema} = Parser.parse_file(schema_path)

        normalized_schema =
          Normalize.normalize(parsed_schema, name: schema_name)

        normalized_schema.definitions
    end
  end

  defp json_schema_path(schema_name) do
    Path.join(@schemas_dir, "#{schema_name}.json")
  end

  defp tl_schema_path(schema_name) do
    Path.join(@schemas_dir, "#{schema_name}.tl")
  end

  defp bare_constructor?(%Definition{tl_name: tl_name}) do
    case tl_name do
      <<first::utf8, _rest::binary>> when first in ?a..?z -> true
      _ -> false
    end
  end
end
