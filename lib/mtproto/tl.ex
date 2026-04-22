defmodule MTProto.TL do
  @moduledoc """
  Minimal TL helpers needed for the first MTProto auth exchange.
  """

  @vector_constructor 0x1CB5C415

  @spec encode_int(integer()) :: binary()
  def encode_int(value)
      when is_integer(value) and value >= -0x8000_0000 and
             value <= 0x7FFF_FFFF do
    <<value::little-signed-32>>
  end

  @spec decode_int(binary()) :: {:ok, integer(), binary()} | {:error, term()}
  def decode_int(<<value::little-signed-32, rest::binary>>),
    do: {:ok, value, rest}

  def decode_int(_), do: {:error, :short_int}

  @spec encode_long(non_neg_integer()) :: binary()
  def encode_long(value)
      when is_integer(value) and value >= 0 and value <= 0xFFFF_FFFF_FFFF_FFFF do
    <<value::little-unsigned-64>>
  end

  @spec decode_long(binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, term()}
  def decode_long(<<value::little-unsigned-64, rest::binary>>),
    do: {:ok, value, rest}

  def decode_long(_), do: {:error, :short_long}

  @spec encode_int128(binary()) :: binary()
  def encode_int128(value) when is_binary(value) and byte_size(value) == 16,
    do: value

  @spec decode_int128(binary()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def decode_int128(<<value::binary-size(16), rest::binary>>),
    do: {:ok, value, rest}

  def decode_int128(_), do: {:error, :short_int128}

  @spec encode_int256(binary()) :: binary()
  def encode_int256(value) when is_binary(value) and byte_size(value) == 32,
    do: value

  @spec decode_int256(binary()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def decode_int256(<<value::binary-size(32), rest::binary>>),
    do: {:ok, value, rest}

  def decode_int256(_), do: {:error, :short_int256}

  @spec encode_bytes(binary()) :: binary()
  def encode_bytes(value) when is_binary(value) do
    size = byte_size(value)

    if size < 254 do
      padding = padding_size(1 + size)
      <<size, value::binary, 0::size(padding)-unit(8)>>
    else
      padding = padding_size(4 + size)

      <<254, size::little-unsigned-size(24), value::binary,
        0::size(padding)-unit(8)>>
    end
  end

  @spec decode_bytes(binary()) :: {:ok, binary(), binary()} | {:error, term()}
  def decode_bytes(<<size, rest::binary>>) when size < 254 do
    padding = padding_size(1 + size)
    needed = size + padding

    if byte_size(rest) < needed do
      {:error, :short_tl_bytes}
    else
      <<value::binary-size(size), _padding::binary-size(padding),
        tail::binary>> = rest

      {:ok, value, tail}
    end
  end

  def decode_bytes(<<254, size::little-unsigned-size(24), rest::binary>>) do
    padding = padding_size(4 + size)
    needed = size + padding

    if byte_size(rest) < needed do
      {:error, :short_tl_bytes}
    else
      <<value::binary-size(size), _padding::binary-size(padding),
        tail::binary>> = rest

      {:ok, value, tail}
    end
  end

  def decode_bytes(_), do: {:error, :short_tl_bytes}

  @spec encode_vector(list(), (term() -> binary())) :: binary()
  def encode_vector(items, encode_item)
      when is_list(items) and is_function(encode_item, 1) do
    body = Enum.map_join(items, encode_item)

    <<@vector_constructor::little-unsigned-32,
      length(items)::little-unsigned-32, body::binary>>
  end

  @spec decode_vector(binary(), (binary() ->
                                   {:ok, term(), binary()} | {:error, term()})) ::
          {:ok, list(), binary()} | {:error, term()}
  def decode_vector(
        <<@vector_constructor::little-unsigned-32, count::little-unsigned-32,
          rest::binary>>,
        decode_item
      )
      when is_function(decode_item, 1) do
    decode_vector_items(count, rest, decode_item, [])
  end

  def decode_vector(_, _), do: {:error, :invalid_vector}

  defp decode_vector_items(0, rest, _decode_item, items),
    do: {:ok, Enum.reverse(items), rest}

  defp decode_vector_items(count, rest, decode_item, items) do
    with {:ok, item, rest} <- decode_item.(rest) do
      decode_vector_items(count - 1, rest, decode_item, [item | items])
    end
  end

  defp padding_size(length) do
    rem(4 - rem(length, 4), 4)
  end
end
