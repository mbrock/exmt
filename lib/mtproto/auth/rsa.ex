defmodule MTProto.Auth.RSA do
  @moduledoc false

  alias MTProto.Auth.{Math, PublicKey}
  alias MTProto.Crypto.IGE

  @rsa_len 256
  @rsa_data_len 235
  @rsa_padded_limit 144
  @data_with_padding_len 192

  @spec encrypt(binary(), PublicKey.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encrypt(data, %PublicKey{mode: :legacy} = key, random_bytes) do
    legacy_encrypt(data, key, random_bytes)
  end

  def encrypt(data, %PublicKey{mode: :padded} = key, random_bytes) do
    padded_encrypt(data, key, random_bytes)
  end

  @spec required_random_bytes(PublicKey.mode(), non_neg_integer()) ::
          non_neg_integer()
  def required_random_bytes(:legacy, data_len)
      when is_integer(data_len) and data_len >= 0 do
    @rsa_data_len + 20
  end

  def required_random_bytes(:padded, data_len)
      when is_integer(data_len) and data_len >= 0 do
    @data_with_padding_len + 32
  end

  defp legacy_encrypt(data, %PublicKey{} = key, random_bytes)
       when is_binary(data) and is_binary(random_bytes) do
    cond do
      byte_size(data) > @rsa_data_len ->
        {:error, :legacy_rsa_data_too_large}

      byte_size(random_bytes) < @rsa_data_len + 20 ->
        {:error, :insufficient_rsa_random_bytes}

      true ->
        <<random_buffer::binary-size(255), _::binary>> = random_bytes

        data_with_hash =
          random_buffer
          |> binary_replace(0, :crypto.hash(:sha, data))
          |> binary_replace(20, data)

        encrypt_block(data_with_hash, key)
    end
  end

  defp legacy_encrypt(_data, _key, _random_bytes),
    do: {:error, :invalid_rsa_input}

  defp padded_encrypt(data, %PublicKey{} = key, random_bytes)
       when is_binary(data) and is_binary(random_bytes) do
    padding_len = @data_with_padding_len - byte_size(data)

    cond do
      byte_size(data) > @rsa_padded_limit ->
        {:error, :rsa_pad_data_too_large}

      byte_size(random_bytes) < @data_with_padding_len + 32 ->
        {:error, :insufficient_rsa_random_bytes}

      true ->
        data_with_padding =
          data <>
            binary_part(random_bytes, 0, padding_len)

        <<temp_key::binary-size(32), _::binary>> =
          binary_part(
            random_bytes,
            @data_with_padding_len,
            byte_size(random_bytes) - @data_with_padding_len
          )

        do_padded_encrypt(
          data_with_padding,
          Math.reverse_bytes(data_with_padding),
          key,
          temp_key
        )
    end
  end

  defp padded_encrypt(_data, _key, _random_bytes),
    do: {:error, :invalid_rsa_input}

  defp do_padded_encrypt(data_with_padding, data_pad_reversed, key, temp_key) do
    data_with_hash =
      data_pad_reversed <>
        :crypto.hash(:sha256, temp_key <> data_with_padding)

    with {:ok, aes_encrypted} <-
           IGE.encrypt(data_with_hash, temp_key, :binary.copy(<<0>>, 32)) do
      candidate =
        :crypto.exor(temp_key, :crypto.hash(:sha256, aes_encrypted)) <>
          aes_encrypted

      candidate_integer = :binary.decode_unsigned(candidate)

      if candidate_integer >= key.modulus do
        do_padded_encrypt(
          data_with_padding,
          data_pad_reversed,
          key,
          Math.increment_be(temp_key)
        )
      else
        encrypt_block(candidate, key)
      end
    end
  end

  defp encrypt_block(block, %PublicKey{modulus: modulus, exponent: exponent})
       when is_binary(block) do
    encrypted =
      block
      |> :binary.decode_unsigned()
      |> Math.mod_pow(exponent, modulus)
      |> Math.encode_unsigned(@rsa_len)

    {:ok, encrypted}
  end

  defp binary_replace(buffer, offset, replacement)
       when is_binary(buffer) and is_integer(offset) and offset >= 0 and
              is_binary(replacement) do
    prefix = binary_part(buffer, 0, offset)
    suffix_offset = offset + byte_size(replacement)
    suffix_len = byte_size(buffer) - suffix_offset
    suffix = binary_part(buffer, suffix_offset, suffix_len)
    prefix <> replacement <> suffix
  end
end
