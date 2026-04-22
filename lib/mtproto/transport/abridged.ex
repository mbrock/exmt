defmodule MTProto.Transport.Abridged do
  @moduledoc """
  Pure abridged transport framing.
  """

  @max_words 16_777_216

  defmodule Decoder do
    @moduledoc false
    defstruct buffer: <<>>
  end

  @spec client_prefix() :: binary()
  def client_prefix, do: <<0xEF>>

  @spec new_decoder() :: Decoder.t()
  def new_decoder, do: %Decoder{}

  @spec encode(binary(), keyword()) :: binary()
  def encode(payload, opts \\ []) when is_binary(payload) and rem(byte_size(payload), 4) == 0 do
    words = div(byte_size(payload), 4)
    quick_ack? = Keyword.get(opts, :quick_ack, false)

    cond do
      words < 0x7F ->
        header = if quick_ack?, do: <<words + 0x80>>, else: <<words>>
        header <> payload

      words < @max_words ->
        tag = if quick_ack?, do: 0xFF, else: 0x7F
        <<tag, words::little-unsigned-size(24), payload::binary>>

      true ->
        raise ArgumentError, "abridged payload is too large: #{byte_size(payload)} bytes"
    end
  end

  @spec feed(Decoder.t(), binary()) :: {:ok, Decoder.t(), [binary() | {:quick_ack, non_neg_integer()}]}
  def feed(%Decoder{buffer: buffer} = decoder, chunk) when is_binary(chunk) do
    decode_frames(%{decoder | buffer: buffer <> chunk}, [])
  end

  defp decode_frames(%Decoder{} = decoder, frames) do
    case decode_one(decoder.buffer) do
      {:ok, frame, rest} ->
        decode_frames(%{decoder | buffer: rest}, [frame | frames])

      :more ->
        {:ok, decoder, Enum.reverse(frames)}
    end
  end

  defp decode_one(<<>>), do: :more

  # The server sends quick-ack packets as 4-byte bswapped standalone tokens.
  defp decode_one(<<first, _::binary>> = buffer) when first >= 0x80 do
    if byte_size(buffer) < 4 do
      :more
    else
      <<raw::little-unsigned-32, rest::binary>> = buffer
      {:ok, {:quick_ack, byte_swap32(raw)}, rest}
    end
  end

  defp decode_one(<<0x7F, words::little-unsigned-size(24), rest::binary>>) do
    take_payload(rest, words)
  end

  defp decode_one(<<0x7F, _::binary>>), do: :more

  defp decode_one(<<words, rest::binary>>) do
    take_payload(rest, words)
  end

  defp take_payload(rest, words) do
    payload_size = words * 4

    if byte_size(rest) < payload_size do
      :more
    else
      <<payload::binary-size(payload_size), tail::binary>> = rest
      {:ok, payload, tail}
    end
  end

  defp byte_swap32(value) do
    <<a, b, c, d>> = <<value::little-unsigned-32>>
    <<swapped::little-unsigned-32>> = <<d, c, b, a>>
    swapped
  end
end
