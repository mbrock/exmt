defmodule MTProto.SampleAuthKey do
  def nonce do
    hex("""
    79 F0 AF B5 02 52 E5 FC
    96 92 4B FC EC DA 4F 05
    """)
  end

  def server_nonce do
    hex("""
    80 17 75 A3 EF BF D2 70
    1A A2 8A D7 27 BE 46 46
    """)
  end

  def req_pq_multi_body do
    hex("""
    F1 8E 7E BE
    79 F0 AF B5 02 52 E5 FC 96 92 4B FC EC DA 4F 05
    """)
  end

  def plain_request do
    hex("""
    00 00 00 00 00 00 00 00
    60 97 05 00 EB E5 77 67
    14 00 00 00
    F1 8E 7E BE 79 F0 AF B5 02 52 E5 FC 96 92 4B FC EC DA 4F 05
    """)
  end

  def plain_response do
    hex("""
    00 00 00 00 00 00 00 00
    01 28 FB D2 EB E5 77 67
    50 00 00 00
    63 24 16 05
    79 F0 AF B5 02 52 E5 FC 96 92 4B FC EC DA 4F 05
    80 17 75 A3 EF BF D2 70 1A A2 8A D7 27 BE 46 46
    08 13 0B 74 75 66 9F EB 8B 00 00 00
    15 C4 B5 1C
    03 00 00 00
    85 FD 64 DE 85 1D 9D D0
    A5 B7 F7 09 35 5F C3 0B
    21 6B E8 6C 02 2B B4 C3
    """)
  end

  def framed_response do
    MTProto.Transport.Abridged.encode(plain_response())
  end

  defp hex(data) do
    data
    |> String.replace(~r/[^0-9A-Fa-f]/, "")
    |> Base.decode16!(case: :mixed)
  end
end

defmodule MTProtoTest do
  use ExUnit.Case, async: true

  alias MTProto.Auth.{KeyExchange, ResPQ}
  alias MTProto.{MessageId, PlainMessage}
  alias MTProto.Transport.Abridged

  test "encodes req_pq_multi from the official sample nonce" do
    assert KeyExchange.encode_req_pq_multi(MTProto.SampleAuthKey.nonce()) ==
             MTProto.SampleAuthKey.req_pq_multi_body()
  end

  test "roundtrips the official sample plain request" do
    {:ok, message} = PlainMessage.decode(MTProto.SampleAuthKey.plain_request())

    assert message.message_id == 0x6777_E5EB_0005_9760
    assert message.body == MTProto.SampleAuthKey.req_pq_multi_body()
    assert PlainMessage.encode(message) == MTProto.SampleAuthKey.plain_request()
  end

  test "decodes the official sample res_pq response" do
    {:ok, message} = PlainMessage.decode(MTProto.SampleAuthKey.plain_response())
    {:ok, res_pq} = KeyExchange.decode_res_pq(message.body)

    assert res_pq == %ResPQ{
             nonce: MTProto.SampleAuthKey.nonce(),
             server_nonce: MTProto.SampleAuthKey.server_nonce(),
             pq: <<0x13, 0x0B, 0x74, 0x75, 0x66, 0x9F, 0xEB, 0x8B>>,
             server_public_key_fingerprints: [
               0xD09D_1D85_DE64_FD85,
               0x0BC3_5F35_09F7_B7A5,
               0xC3B4_2B02_6CE8_6B21
             ]
           }

    assert :binary.decode_unsigned(res_pq.pq) == 1_372_318_559_046_200_203
  end

  test "abridged framing keeps partial state until a full frame arrives" do
    encoded = Abridged.encode(MTProto.SampleAuthKey.plain_request())
    <<head::binary-size(5), tail::binary>> = encoded

    assert Abridged.client_prefix() == <<0xEF>>

    {:ok, decoder, []} = Abridged.feed(Abridged.new_decoder(), head)
    {:ok, %Abridged.Decoder{buffer: <<>>}, [frame]} = Abridged.feed(decoder, tail)

    assert frame == MTProto.SampleAuthKey.plain_request()
  end

  test "abridged framing decodes quick ack tokens" do
    {:ok, _decoder, [{:quick_ack, token}]} =
      Abridged.feed(Abridged.new_decoder(), <<0x81, 0x23, 0x45, 0x67>>)

    assert token == 0x8123_4567
  end

  test "message ids stay monotonic and keep a non-zero fractional part" do
    first = MessageId.next(nil, 1_713_534_000_000_000_000)
    second = MessageId.next(first, 1_713_534_000_000_000_000)

    assert rem(first, 4) == 0
    assert rem(second, 4) == 0
    assert second == first + 4

    integer_seconds_part = div(first, 4_294_967_296) * 4_294_967_296
    assert first > integer_seconds_part
  end

  test "core emits bytes for req_pq_multi and advances on res_pq" do
    state = MTProto.new()

    {:ok, state, effects} =
      MTProto.begin_auth_key_exchange(state, 1_713_534_000_000_000_000, MTProto.SampleAuthKey.nonce())

    assert state.phase == :awaiting_res_pq
    assert state.pending_nonce == MTProto.SampleAuthKey.nonce()

    assert [
             {:send_bytes, <<0xEF>>},
             {:send_bytes, outbound},
             {:notify, {:request_sent, :req_pq_multi, msg_id}}
           ] = effects

    assert msg_id == state.last_msg_id

    assert outbound ==
             Abridged.encode(
               PlainMessage.encode(%PlainMessage{
                 message_id: msg_id,
                 body: MTProto.SampleAuthKey.req_pq_multi_body()
               })
             )

    {:ok, state, effects} = MTProto.receive_bytes(state, MTProto.SampleAuthKey.framed_response())

    assert state.phase == :awaiting_dh_params
    assert state.server_nonce == MTProto.SampleAuthKey.server_nonce()

    assert [{:notify, {:res_pq, response_msg_id, %ResPQ{} = res_pq}}] = effects
    assert response_msg_id == 0x6777_E5EB_D2FB_2801
    assert res_pq.nonce == MTProto.SampleAuthKey.nonce()
  end
end
