defmodule MTProto.Auth.ExchangeCrypto do
  @moduledoc false

  alias MTProto.Crypto.IGE

  @spec temp_aes_key_iv(binary(), binary()) ::
          {:ok, {binary(), binary()}} | {:error, term()}
  def temp_aes_key_iv(server_nonce, new_nonce)
      when is_binary(server_nonce) and byte_size(server_nonce) == 16 and
             is_binary(new_nonce) and byte_size(new_nonce) == 32 do
    hash_a = :crypto.hash(:sha, new_nonce <> server_nonce)
    hash_b = :crypto.hash(:sha, server_nonce <> new_nonce)
    hash_c = :crypto.hash(:sha, new_nonce <> new_nonce)

    key = hash_a <> binary_part(hash_b, 0, 12)
    iv = binary_part(hash_b, 12, 8) <> hash_c <> binary_part(new_nonce, 0, 4)

    {:ok, {key, iv}}
  end

  def temp_aes_key_iv(_server_nonce, _new_nonce), do: {:error, :invalid_nonce}

  @spec decrypt_data_with_hash(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def decrypt_data_with_hash(ciphertext, key, iv)
      when is_binary(ciphertext) and rem(byte_size(ciphertext), 16) == 0 and
             is_binary(key) and byte_size(key) == 32 and
             is_binary(iv) and byte_size(iv) == 32 do
    with {:ok, plaintext} <- IGE.decrypt(ciphertext, key, iv) do
      case guess_data_with_hash(plaintext) do
        nil -> {:error, :invalid_data_with_hash}
        data -> {:ok, data}
      end
    end
  end

  def decrypt_data_with_hash(_ciphertext, _key, _iv),
    do: {:error, :invalid_exchange_ciphertext}

  @spec encrypt_data_with_hash(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encrypt_data_with_hash(data, key, iv, padding_bytes)
      when is_binary(data) and is_binary(key) and byte_size(key) == 32 and
             is_binary(iv) and byte_size(iv) == 32 and
             is_binary(padding_bytes) do
    padding_len = rem(16 - rem(20 + byte_size(data), 16), 16)

    if byte_size(padding_bytes) < padding_len do
      {:error, :insufficient_padding_bytes}
    else
      plaintext =
        :crypto.hash(:sha, data) <>
          data <>
          binary_part(padding_bytes, 0, padding_len)

      IGE.encrypt(plaintext, key, iv)
    end
  end

  def encrypt_data_with_hash(_data, _key, _iv, _padding_bytes),
    do: {:error, :invalid_exchange_plaintext}

  @spec server_dh_fail_hash(binary()) :: {:ok, binary()} | {:error, term()}
  def server_dh_fail_hash(new_nonce)
      when is_binary(new_nonce) and byte_size(new_nonce) == 32 do
    digest = :crypto.hash(:sha, new_nonce)
    {:ok, binary_part(digest, 4, 16)}
  end

  def server_dh_fail_hash(_new_nonce), do: {:error, :invalid_new_nonce}

  @spec server_salt(binary(), binary()) :: {:ok, integer()} | {:error, term()}
  def server_salt(new_nonce, server_nonce)
      when is_binary(new_nonce) and byte_size(new_nonce) == 32 and
             is_binary(server_nonce) and byte_size(server_nonce) == 16 do
    salt_bytes =
      :crypto.exor(
        binary_part(new_nonce, 0, 8),
        binary_part(server_nonce, 0, 8)
      )

    <<salt::little-signed-64>> = salt_bytes
    {:ok, salt}
  end

  def server_salt(_new_nonce, _server_nonce), do: {:error, :invalid_nonce}

  defp guess_data_with_hash(<<hash::binary-size(20), rest::binary>>) do
    Enum.find_value(0..15, fn padding_len ->
      if byte_size(rest) >= padding_len do
        data = binary_part(rest, 0, byte_size(rest) - padding_len)

        if :crypto.hash(:sha, data) == hash do
          data
        end
      end
    end)
  end

  defp guess_data_with_hash(_), do: nil
end
