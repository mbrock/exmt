defmodule MTProto.Crypto do
  @moduledoc """
  Pure MTProto 2.0 cryptographic envelope helpers.

  This layer only knows about:

    * `auth_key_id`
    * `msg_key`
    * AES-256-IGE encryption/decryption

  It does not know how the decrypted plaintext is structured.
  """

  alias MTProto.AuthKey
  alias MTProto.Crypto.IGE

  @type sender :: :client | :server

  @spec message_key(AuthKey.t(), binary(), sender()) ::
          {:ok, binary()} | {:error, term()}
  def message_key(%AuthKey{data: data}, plaintext, sender)
      when is_binary(plaintext) and sender in [:client, :server] do
    x = sender_offset(sender)
    digest = :crypto.hash(:sha256, binary_part(data, 88 + x, 32) <> plaintext)
    {:ok, binary_part(digest, 8, 16)}
  end

  def message_key(%AuthKey{}, _plaintext, _sender),
    do: {:error, :invalid_sender}

  @spec aes_key_iv(AuthKey.t(), binary(), sender()) ::
          {:ok, {binary(), binary()}} | {:error, term()}
  def aes_key_iv(%AuthKey{data: data}, msg_key, sender)
      when is_binary(msg_key) and byte_size(msg_key) == 16 and
             sender in [:client, :server] do
    x = sender_offset(sender)
    sha256_a = :crypto.hash(:sha256, msg_key <> binary_part(data, x, 36))
    sha256_b = :crypto.hash(:sha256, binary_part(data, 40 + x, 36) <> msg_key)

    aes_key =
      binary_part(sha256_a, 0, 8) <>
        binary_part(sha256_b, 8, 16) <>
        binary_part(sha256_a, 24, 8)

    aes_iv =
      binary_part(sha256_b, 0, 8) <>
        binary_part(sha256_a, 8, 16) <>
        binary_part(sha256_b, 24, 8)

    {:ok, {aes_key, aes_iv}}
  end

  def aes_key_iv(%AuthKey{}, _msg_key, sender)
      when sender not in [:client, :server] do
    {:error, :invalid_sender}
  end

  def aes_key_iv(%AuthKey{}, _msg_key, _sender),
    do: {:error, :invalid_msg_key}

  @spec encrypt_padded(binary(), AuthKey.t(), sender()) ::
          {:ok, binary()} | {:error, term()}
  def encrypt_padded(plaintext, %AuthKey{} = auth_key, sender)
      when is_binary(plaintext) and sender in [:client, :server] do
    with :ok <- validate_padded_plaintext(plaintext),
         {:ok, msg_key} <- message_key(auth_key, plaintext, sender),
         {:ok, {aes_key, aes_iv}} <- aes_key_iv(auth_key, msg_key, sender),
         {:ok, ciphertext} <- IGE.encrypt(plaintext, aes_key, aes_iv) do
      {:ok, auth_key.id <> msg_key <> ciphertext}
    end
  end

  def encrypt_padded(_plaintext, %AuthKey{}, _sender),
    do: {:error, :invalid_sender}

  @spec decrypt_padded(binary(), AuthKey.t(), sender()) ::
          {:ok, binary()} | {:error, term()}
  def decrypt_padded(
        <<auth_key_id::binary-size(8), msg_key::binary-size(16),
          ciphertext::binary>>,
        %AuthKey{} = auth_key,
        sender
      )
      when sender in [:client, :server] do
    with :ok <- validate_ciphertext(ciphertext),
         :ok <- compare_auth_key_id(auth_key.id, auth_key_id),
         {:ok, {aes_key, aes_iv}} <- aes_key_iv(auth_key, msg_key, sender),
         {:ok, plaintext} <- IGE.decrypt(ciphertext, aes_key, aes_iv),
         {:ok, expected_msg_key} <- message_key(auth_key, plaintext, sender),
         :ok <- compare_msg_key(msg_key, expected_msg_key) do
      {:ok, plaintext}
    end
  end

  def decrypt_padded(payload, %AuthKey{}, _sender)
      when is_binary(payload) and byte_size(payload) < 24 do
    {:error, :short_encrypted_payload}
  end

  def decrypt_padded(_payload, %AuthKey{}, _sender),
    do: {:error, :invalid_sender}

  defp validate_padded_plaintext(plaintext)
       when byte_size(plaintext) > 0 and rem(byte_size(plaintext), 16) == 0,
       do: :ok

  defp validate_padded_plaintext(_), do: {:error, :invalid_padded_plaintext}

  defp validate_ciphertext(ciphertext)
       when byte_size(ciphertext) > 0 and rem(byte_size(ciphertext), 16) == 0,
       do: :ok

  defp validate_ciphertext(_), do: {:error, :invalid_encrypted_payload}

  defp compare_auth_key_id(auth_key_id, auth_key_id), do: :ok

  defp compare_auth_key_id(_expected, _actual),
    do: {:error, :auth_key_id_mismatch}

  defp compare_msg_key(msg_key, msg_key), do: :ok
  defp compare_msg_key(_expected, _actual), do: {:error, :msg_key_mismatch}

  defp sender_offset(:client), do: 0
  defp sender_offset(:server), do: 8
end
