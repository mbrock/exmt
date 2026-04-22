defmodule MTProto.EncryptedPacket do
  @moduledoc """
  MTProto encrypted-message plaintext layout plus the surrounding crypto envelope.
  """

  alias MTProto.AuthKey
  alias MTProto.Crypto

  @min_padding 12
  @max_padding 1024

  @enforce_keys [:salt, :session_id, :message_id, :seq_no, :body]
  defstruct [:salt, :session_id, :message_id, :seq_no, :body, padding: <<>>]

  @type t :: %__MODULE__{
          salt: integer(),
          session_id: integer(),
          message_id: integer(),
          seq_no: integer(),
          body: binary(),
          padding: binary()
        }

  @spec encode_plaintext(t()) :: {:ok, binary()} | {:error, term()}
  def encode_plaintext(%__MODULE__{} = packet) do
    with :ok <- validate_body(packet.body),
         :ok <- validate_padding(packet.body, packet.padding) do
      plaintext =
        <<packet.salt::little-signed-64, packet.session_id::little-signed-64,
          packet.message_id::little-signed-64,
          packet.seq_no::little-signed-32,
          byte_size(packet.body)::little-signed-32, packet.body::binary,
          packet.padding::binary>>

      {:ok, plaintext}
    end
  end

  @spec decode_plaintext(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode_plaintext(plaintext, opts \\ [])

  def decode_plaintext(
        <<salt::little-signed-64, session_id::little-signed-64,
          message_id::little-signed-64, seq_no::little-signed-32,
          body_len::little-signed-32, rest::binary>>,
        opts
      ) do
    with :ok <- validate_body_length(body_len, rest),
         <<body::binary-size(body_len), padding::binary>> <- rest,
         :ok <- validate_padding(body, padding),
         :ok <- validate_expected_session(session_id, opts) do
      {:ok,
       %__MODULE__{
         salt: salt,
         session_id: session_id,
         message_id: message_id,
         seq_no: seq_no,
         body: body,
         padding: padding
       }}
    end
  end

  def decode_plaintext(_plaintext, _opts),
    do: {:error, :short_encrypted_plaintext}

  @spec encode(t(), AuthKey.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = packet, %AuthKey{} = auth_key, opts \\ []) do
    sender = Keyword.get(opts, :sender, :client)

    with {:ok, packet} <- ensure_padding(packet, opts),
         {:ok, plaintext} <- encode_plaintext(packet),
         {:ok, encrypted} <-
           Crypto.encrypt_padded(plaintext, auth_key, sender) do
      {:ok, encrypted}
    end
  end

  @spec decode(binary(), AuthKey.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def decode(payload, %AuthKey{} = auth_key, opts \\ [])
      when is_binary(payload) do
    sender = Keyword.get(opts, :sender, :server)

    with {:ok, plaintext} <- Crypto.decrypt_padded(payload, auth_key, sender),
         {:ok, packet} <- decode_plaintext(plaintext, opts) do
      {:ok, packet}
    end
  end

  defp ensure_padding(%__MODULE__{padding: padding} = packet, _opts)
       when byte_size(padding) > 0 do
    {:ok, packet}
  end

  defp ensure_padding(%__MODULE__{} = packet, opts) do
    plaintext_len = 32 + byte_size(packet.body)
    padding_len = default_padding_length(plaintext_len)

    with {:ok, padding} <-
           take_padding_bytes(
             Keyword.get(opts, :padding_bytes, <<>>),
             padding_len
           ) do
      {:ok, %{packet | padding: padding}}
    end
  end

  defp validate_body(body)
       when is_binary(body) and rem(byte_size(body), 4) == 0,
       do: :ok

  defp validate_body(_), do: {:error, :invalid_body}

  defp validate_padding(body, padding)
       when is_binary(body) and is_binary(padding) and
              byte_size(padding) in @min_padding..@max_padding and
              rem(32 + byte_size(body) + byte_size(padding), 16) == 0,
       do: :ok

  defp validate_padding(_body, _padding), do: {:error, :invalid_padding}

  defp validate_body_length(body_len, _rest) when body_len < 0,
    do: {:error, :invalid_body_length}

  defp validate_body_length(body_len, rest)
       when rem(body_len, 4) != 0 or body_len > byte_size(rest) do
    {:error, :invalid_body_length}
  end

  defp validate_body_length(_body_len, _rest), do: :ok

  defp validate_expected_session(actual_session_id, opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, expected_session_id}
      when expected_session_id == actual_session_id ->
        :ok

      {:ok, _expected_session_id} ->
        {:error, :session_id_mismatch}

      :error ->
        :ok
    end
  end

  defp default_padding_length(plaintext_len) do
    16 + (16 - rem(plaintext_len, 16))
  end

  defp take_padding_bytes(bytes, count)
       when is_binary(bytes) and byte_size(bytes) >= count do
    {:ok, binary_part(bytes, 0, count)}
  end

  defp take_padding_bytes(_bytes, _count),
    do: {:error, :insufficient_padding_bytes}
end
