defmodule MTProto.Auth.KeyExchange do
  @moduledoc """
  Minimal TL objects for the first auth-key exchange roundtrip.
  """

  alias MTProto.Auth.ResPQ
  alias MTProto.TL

  @req_pq_multi 0xBE7E8EF1
  @res_pq 0x05162463

  @spec encode_req_pq_multi(binary()) :: binary()
  def encode_req_pq_multi(nonce)
      when is_binary(nonce) and byte_size(nonce) == 16 do
    <<@req_pq_multi::little-unsigned-32, nonce::binary>>
  end

  @spec decode_res_pq(binary()) :: {:ok, ResPQ.t()} | {:error, term()}
  def decode_res_pq(<<@res_pq::little-unsigned-32, rest::binary>>) do
    with {:ok, nonce, rest} <- TL.decode_int128(rest),
         {:ok, server_nonce, rest} <- TL.decode_int128(rest),
         {:ok, pq, rest} <- TL.decode_bytes(rest),
         {:ok, fingerprints, <<>>} <-
           TL.decode_vector(rest, &TL.decode_long/1) do
      {:ok,
       %ResPQ{
         nonce: nonce,
         server_nonce: server_nonce,
         pq: pq,
         server_public_key_fingerprints: fingerprints
       }}
    else
      {:ok, _fingerprints, _rest} -> {:error, :trailing_tl_data}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_res_pq(<<constructor::little-unsigned-32, _::binary>>) do
    {:error, {:unexpected_constructor, constructor}}
  end

  def decode_res_pq(_), do: {:error, :short_res_pq}
end
