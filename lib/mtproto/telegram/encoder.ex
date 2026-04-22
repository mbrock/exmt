defmodule MTProto.Telegram.Encoder do
  @moduledoc false

  import Bitwise

  alias MTProto.TL
  alias MTProto.TL.Runtime.Decoded
  alias MTProto.TL.Schema.Definition
  alias MTProto.TL.Schema.Param
  alias MTProto.TL.Schema.TypeExpr
  alias MTProto.Telegram.Schema

  @min_signed_long -0x8000_0000_0000_0000
  @max_signed_long 0x7FFF_FFFF_FFFF_FFFF

  @spec encode_method(binary(), keyword() | map()) ::
          {:ok, binary()} | {:error, term()}
  def encode_method(method, params) when is_binary(method) do
    with {:ok, definition} <- fetch_function(method),
         {:ok, encoded} <- encode_definition(definition, params, boxed: true) do
      {:ok, encoded}
    end
  end

  @spec encode_definition(Definition.t(), keyword() | map(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def encode_definition(%Definition{} = definition, params, opts \\ []) do
    with {:ok, fields} <- normalize_fields(params),
         {:ok, flags_state} <- build_flags(definition.params, fields, %{}),
         {:ok, body} <-
           encode_params(definition.params, fields, flags_state, []) do
      encoded =
        case Keyword.get(opts, :boxed, true) do
          true ->
            [<<definition.id::little-unsigned-32>>, body]

          false ->
            body
        end

      {:ok, IO.iodata_to_binary(encoded)}
    end
  end

  defp fetch_function(method) do
    case Schema.function(method) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:unknown_telegram_method, method}}
    end
  end

  defp fetch_constructor(name) do
    case Schema.constructor(name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:unknown_telegram_constructor, name}}
    end
  end

  defp normalize_fields(params) when is_list(params) do
    if Keyword.keyword?(params) do
      {:ok, Map.new(params)}
    else
      {:error, :invalid_request_params}
    end
  end

  defp normalize_fields(params) when is_map(params), do: {:ok, params}
  defp normalize_fields(nil), do: {:ok, %{}}
  defp normalize_fields(_params), do: {:error, :invalid_request_params}

  defp build_flags([], _fields, flags_state), do: {:ok, flags_state}

  defp build_flags([%Param{} = param | rest], fields, flags_state) do
    case param.type do
      %TypeExpr.Special{value: "#"} ->
        build_flags(
          rest,
          fields,
          Map.put_new(flags_state, field_key(param), 0)
        )

      %TypeExpr.Flag{field: flag_field, bit: bit, type: inner_type} ->
        flags_state =
          if flag_present?(fields, field_key(param), inner_type) do
            Map.update(
              flags_state,
              flag_field,
              1 <<< bit,
              &(&1 ||| 1 <<< bit)
            )
          else
            flags_state
          end

        build_flags(rest, fields, flags_state)

      _type ->
        build_flags(rest, fields, flags_state)
    end
  end

  defp encode_params([], _fields, _flags_state, encoded),
    do: {:ok, Enum.reverse(encoded)}

  defp encode_params([%Param{} = param | rest], fields, flags_state, encoded) do
    with {:ok, value} <- encode_param(param, fields, flags_state) do
      encode_params(rest, fields, flags_state, [value | encoded])
    end
  end

  defp encode_param(
         %Param{type: %TypeExpr.Special{value: "#"}} = param,
         _fields,
         flags_state
       ) do
    {:ok, TL.encode_int(Map.get(flags_state, field_key(param), 0))}
  end

  defp encode_param(
         %Param{
           type: %TypeExpr.Flag{
             field: flags_field,
             bit: bit,
             type: inner_type
           }
         } = param,
         fields,
         flags_state
       ) do
    flags_value = Map.get(flags_state, flags_field, 0)

    if flag_set?(flags_value, bit) do
      case inner_type do
        %TypeExpr.Ref{name: "true", kind: :builtin} ->
          {:ok, []}

        _ ->
          with {:ok, value} <- fetch_present_field(fields, field_key(param)),
               {:ok, encoded} <- encode_type(inner_type, value) do
            {:ok, encoded}
          end
      end
    else
      {:ok, []}
    end
  end

  defp encode_param(%Param{type: type} = param, fields, _flags_state) do
    key = field_key(param)

    case fetch_present_field(fields, key) do
      {:ok, value} ->
        encode_type(type, value)

      :error ->
        case encode_type(type, nil) do
          {:ok, encoded} ->
            {:ok, encoded}

          {:error, :missing_value} ->
            {:error, {:missing_option, key}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp encode_type(%TypeExpr.Bang{type: type}, value),
    do: encode_type(type, value)

  defp encode_type(%TypeExpr.Bare{type: type}, value),
    do: encode_type(type, value)

  defp encode_type(
         %TypeExpr.Vector{item_type: item_type, boxing: :boxed},
         value
       )
       when is_list(value) do
    with {:ok, items} <- encode_items(value, item_type, []) do
      {:ok, TL.encode_vector(items, &IO.iodata_to_binary/1)}
    end
  end

  defp encode_type(
         %TypeExpr.Vector{item_type: item_type, boxing: :bare},
         value
       )
       when is_list(value) do
    with {:ok, items} <- encode_items(value, item_type, []) do
      {:ok, [TL.encode_int(length(value)) | items] |> IO.iodata_to_binary()}
    end
  end

  defp encode_type(%TypeExpr.Vector{}, _value), do: {:error, :invalid_vector}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int"}, value),
    do: encode_int(value)

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int32"}, value),
    do: encode_int(value)

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int53"}, value),
    do: encode_signed_long(value)

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int64"}, value),
    do: encode_signed_long(value)

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "long"}, value),
    do: encode_signed_long(value)

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int128"}, value)
       when is_binary(value) and byte_size(value) == 16,
       do: {:ok, TL.encode_int128(value)}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int128"}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int128"}, _value),
    do: {:error, :invalid_int128}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int256"}, value)
       when is_binary(value) and byte_size(value) == 32,
       do: {:ok, TL.encode_int256(value)}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int256"}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "int256"}, _value),
    do: {:error, :invalid_int256}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "double"}, value)
       when is_float(value),
       do: {:ok, <<value::little-float-64>>}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "double"}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "double"}, _value),
    do: {:error, :invalid_double}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "string"}, value)
       when is_binary(value),
       do: {:ok, TL.encode_bytes(value)}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "string"}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "string"}, _value),
    do: {:error, :invalid_string}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "bytes"}, value)
       when is_binary(value),
       do: {:ok, TL.encode_bytes(value)}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "bytes"}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "bytes"}, _value),
    do: {:error, :invalid_bytes}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "true"}, true),
    do: {:ok, <<>>}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "true"}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :builtin, name: "true"}, _value),
    do: {:error, :invalid_true}

  defp encode_type(%TypeExpr.Ref{kind: :generic}, value)
       when is_binary(value),
       do: {:ok, value}

  defp encode_type(%TypeExpr.Ref{kind: :generic}, nil),
    do: {:error, :missing_value}

  defp encode_type(%TypeExpr.Ref{kind: :generic}, _value),
    do: {:error, :invalid_generic_value}

  defp encode_type(
         %TypeExpr.Ref{kind: :type, boxing: :boxed, name: "Bool"},
         value
       )
       when is_boolean(value),
       do: {:ok, TL.encode_bool(value)}

  defp encode_type(
         %TypeExpr.Ref{kind: :type, boxing: :boxed, name: "Bool"},
         nil
       ),
       do: {:error, :missing_value}

  defp encode_type(
         %TypeExpr.Ref{kind: :type, boxing: :boxed, name: "Bool"},
         _value
       ),
       do: {:error, :invalid_bool}

  defp encode_type(
         %TypeExpr.Ref{kind: :type, boxing: :boxed, name: type_name},
         value
       ) do
    with {:ok, definition, constructor_params} <-
           select_boxed_constructor(type_name, value),
         {:ok, encoded} <-
           encode_definition(definition, constructor_params, boxed: true) do
      {:ok, encoded}
    end
  end

  defp encode_type(
         %TypeExpr.Ref{
           kind: :constructor,
           boxing: :bare,
           name: constructor_name
         },
         value
       ) do
    with {:ok, definition} <- fetch_constructor(constructor_name),
         {:ok, constructor_params} <-
           bare_constructor_params(definition, value),
         {:ok, encoded} <-
           encode_definition(definition, constructor_params, boxed: false) do
      {:ok, encoded}
    end
  end

  defp encode_type(type, _value), do: {:error, {:unsupported_type, type}}

  defp encode_items([], _item_type, encoded), do: {:ok, Enum.reverse(encoded)}

  defp encode_items([item | rest], item_type, encoded) do
    with {:ok, encoded_item} <- encode_type(item_type, item) do
      encode_items(rest, item_type, [encoded_item | encoded])
    end
  end

  defp select_boxed_constructor(type_name, nil) do
    case defaultable_constructor(type_name) do
      {:ok, definition} -> {:ok, definition, []}
      :error -> {:error, :missing_value}
    end
  end

  defp select_boxed_constructor(type_name, value) do
    case normalize_special_value(type_name, value) do
      %Decoded{tl_name: constructor_name, fields: fields} ->
        explicit_constructor(type_name, constructor_name, fields)

      {constructor_name, constructor_params}
      when is_binary(constructor_name) and
             (is_list(constructor_params) or is_map(constructor_params)) ->
        explicit_constructor(type_name, constructor_name, constructor_params)

      constructor_params
      when is_list(constructor_params) or is_map(constructor_params) ->
        case Schema.constructors_for_type(type_name) do
          [definition] -> {:ok, definition, constructor_params}
          [] -> {:error, {:unknown_telegram_type, type_name}}
          _definitions -> {:error, {:ambiguous_constructor, type_name}}
        end

      _other ->
        {:error, {:invalid_constructor_value, type_name}}
    end
  end

  defp explicit_constructor(type_name, constructor_name, constructor_params) do
    with {:ok, definition} <- fetch_constructor(constructor_name),
         :ok <- validate_constructor_type(definition, type_name) do
      {:ok, definition, constructor_params}
    end
  end

  defp bare_constructor_params(
         %Definition{tl_name: constructor_name} = definition,
         value
       ) do
    case value do
      %Decoded{tl_name: ^constructor_name, fields: fields} ->
        {:ok, fields}

      constructor_params
      when is_list(constructor_params) or is_map(constructor_params) ->
        {:ok, constructor_params}

      nil when definition.params == [] ->
        {:ok, []}

      nil ->
        {:error, :missing_value}

      _other ->
        {:error, {:invalid_constructor_value, constructor_name}}
    end
  end

  defp defaultable_constructor(type_name) do
    case Schema.constructors_for_type(type_name) do
      [definition] ->
        if constructor_params_optional?(definition.params) do
          {:ok, definition}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp constructor_params_optional?(params) do
    Enum.all?(params, fn
      %Param{type: %TypeExpr.Special{value: "#"}} -> true
      %Param{type: %TypeExpr.Flag{}} -> true
      _ -> false
    end)
  end

  defp validate_constructor_type(
         %Definition{} = definition,
         expected_type_name
       ) do
    case Schema.result_type_name(definition) do
      ^expected_type_name ->
        :ok

      actual_type_name ->
        {:error,
         {:unexpected_constructor_type, definition.tl_name, actual_type_name,
          expected_type_name}}
    end
  end

  defp normalize_special_value("InputPeer", :empty),
    do: {"inputPeerEmpty", []}

  defp normalize_special_value("InputPeer", :self), do: {"inputPeerSelf", []}

  defp normalize_special_value("InputPeer", {:chat, chat_id})
       when is_integer(chat_id),
       do: {"inputPeerChat", [chat_id: chat_id]}

  defp normalize_special_value("InputPeer", {:user, user_id, access_hash})
       when is_integer(user_id) and is_integer(access_hash),
       do: {"inputPeerUser", [user_id: user_id, access_hash: access_hash]}

  defp normalize_special_value(
         "InputPeer",
         {:channel, channel_id, access_hash}
       )
       when is_integer(channel_id) and is_integer(access_hash),
       do:
         {"inputPeerChannel",
          [channel_id: channel_id, access_hash: access_hash]}

  defp normalize_special_value("InputUser", :self), do: {"inputUserSelf", []}

  defp normalize_special_value(_type_name, value), do: value

  defp fetch_present_field(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp field_key(%Param{field: field}) when not is_nil(field), do: field

  defp field_key(%Param{tl_name: tl_name}) when is_binary(tl_name),
    do: String.to_atom(tl_name)

  defp field_key(_param), do: :value

  defp flag_present?(fields, key, %TypeExpr.Ref{name: "true", kind: :builtin}) do
    Map.get(fields, key) == true
  end

  defp flag_present?(fields, key, _inner_type) do
    Map.has_key?(fields, key) and not is_nil(Map.get(fields, key))
  end

  defp flag_set?(flags_value, bit)
       when is_integer(flags_value) and is_integer(bit) and bit >= 0 do
    (flags_value &&& 1 <<< bit) != 0
  end

  defp encode_int(value)
       when is_integer(value) and value >= -0x8000_0000 and
              value <= 0x7FFF_FFFF do
    {:ok, TL.encode_int(value)}
  end

  defp encode_int(nil), do: {:error, :missing_value}
  defp encode_int(_value), do: {:error, :invalid_int}

  defp encode_signed_long(value)
       when is_integer(value) and value >= @min_signed_long and
              value <= @max_signed_long do
    {:ok, TL.encode_signed_long(value)}
  end

  defp encode_signed_long(nil), do: {:error, :missing_value}
  defp encode_signed_long(_value), do: {:error, :invalid_long}
end
