defmodule MTProto.PlainMessage do
  @moduledoc """
  Codec for the unencrypted MTProto message envelope used during auth bootstrap.
  """

  @enforce_keys [:message_id, :body]
  defstruct [:message_id, :body]

  @type t :: %__MODULE__{
          message_id: non_neg_integer(),
          body: binary()
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{message_id: message_id, body: body})
      when is_integer(message_id) and message_id >= 0 and is_binary(body) and
             byte_size(body) <= 0xFFFF_FFFF do
    <<0::little-unsigned-64, message_id::little-unsigned-64, byte_size(body)::little-unsigned-32,
      body::binary>>
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(
        <<0::little-unsigned-64, message_id::little-unsigned-64, body_len::little-unsigned-32,
          rest::binary>>
      ) do
    if byte_size(rest) < body_len do
      {:error, :short_plain_message}
    else
      <<body::binary-size(body_len), trailing::binary>> = rest

      case trailing do
        <<>> -> {:ok, %__MODULE__{message_id: message_id, body: body}}
        _ -> {:error, :trailing_bytes}
      end
    end
  end

  def decode(<<_auth_key_id::little-unsigned-64, _::binary>>) do
    {:error, :encrypted_messages_not_supported}
  end

  def decode(_), do: {:error, :short_plain_message}
end
