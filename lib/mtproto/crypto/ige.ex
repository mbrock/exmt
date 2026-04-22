defmodule MTProto.Crypto.IGE do
  @moduledoc """
  Pure AES-256-IGE implementation over OTP's AES-ECB primitive.
  """

  @block_size 16

  @spec encrypt(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encrypt(data, key, iv)
      when is_binary(data) and is_binary(key) and is_binary(iv) do
    with :ok <- validate_lengths(data, key, iv) do
      <<prev_cipher::binary-size(@block_size),
        prev_plain::binary-size(@block_size)>> = iv

      {:ok, encrypt_blocks(data, key, prev_cipher, prev_plain, [])}
    end
  end

  @spec decrypt(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def decrypt(data, key, iv)
      when is_binary(data) and is_binary(key) and is_binary(iv) do
    with :ok <- validate_lengths(data, key, iv) do
      <<prev_cipher::binary-size(@block_size),
        prev_plain::binary-size(@block_size)>> = iv

      {:ok, decrypt_blocks(data, key, prev_cipher, prev_plain, [])}
    end
  end

  defp validate_lengths(data, key, iv)
       when byte_size(key) == 32 and byte_size(iv) == 32 and
              rem(byte_size(data), @block_size) == 0,
       do: :ok

  defp validate_lengths(_data, key, _iv) when byte_size(key) != 32,
    do: {:error, :invalid_aes_key}

  defp validate_lengths(_data, _key, iv) when byte_size(iv) != 32,
    do: {:error, :invalid_aes_iv}

  defp validate_lengths(_data, _key, _iv), do: {:error, :invalid_ige_data}

  defp encrypt_blocks(<<>>, _key, _prev_cipher, _prev_plain, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp encrypt_blocks(
         <<block::binary-size(@block_size), rest::binary>>,
         key,
         prev_cipher,
         prev_plain,
         acc
       ) do
    ciphertext =
      block
      |> :crypto.exor(prev_cipher)
      |> encrypt_block(key)
      |> :crypto.exor(prev_plain)

    encrypt_blocks(rest, key, ciphertext, block, [ciphertext | acc])
  end

  defp decrypt_blocks(<<>>, _key, _prev_cipher, _prev_plain, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp decrypt_blocks(
         <<block::binary-size(@block_size), rest::binary>>,
         key,
         prev_cipher,
         prev_plain,
         acc
       ) do
    plaintext =
      block
      |> :crypto.exor(prev_plain)
      |> decrypt_block(key)
      |> :crypto.exor(prev_cipher)

    decrypt_blocks(rest, key, block, plaintext, [plaintext | acc])
  end

  defp encrypt_block(block, key) do
    :crypto.crypto_one_time(:aes_256_ecb, key, block, true)
  end

  defp decrypt_block(block, key) do
    :crypto.crypto_one_time(:aes_256_ecb, key, block, false)
  end
end
