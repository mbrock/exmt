defmodule MTProto.SessionTest do
  use ExUnit.Case, async: true

  alias MTProto.Auth.ExchangeResult
  alias MTProto.{AuthKey, EncryptedPacket, MessageId, Session, TL}

  test "sends ping as an encrypted service message with time-adjusted msg_id" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    {:ok, session} =
      Session.new(
        %ExchangeResult{auth_key: auth_key, server_salt: 42, time_offset: 5},
        session_id: 123,
        last_msg_id: 100
      )

    padding_bytes = :binary.copy(<<0xAA>>, 64)
    now_ns = 1_000_000_000
    ping_id = 99

    assert {:ok, next_session, effects} =
             Session.send_ping(session, now_ns, ping_id,
               padding_bytes: padding_bytes
             )

    assert [{:send_encrypted, encrypted} | _] = effects

    assert {:ok, packet} =
             EncryptedPacket.decode(encrypted, auth_key,
               sender: :client,
               session_id: 123
             )

    expected_msg_id =
      MessageId.next(100, now_ns + 5_000_000_000)

    assert packet.salt == 42
    assert packet.message_id == expected_msg_id
    assert packet.seq_no == 0
    assert packet.body == ping_body(ping_id)

    assert next_session.last_msg_id == expected_msg_id
    assert next_session.sent_content_messages == 0

    assert notifications(effects) == [
             {:encrypted_packet_sent, packet},
             {:session_message_sent, expected_msg_id, 0, ping_body(ping_id)},
             {:ping_sent, expected_msg_id, ping_id}
           ]
  end

  test "updates server salt from bad_server_salt and acknowledges odd packets" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    {:ok, session} =
      Session.new(
        %ExchangeResult{auth_key: auth_key, server_salt: 42, time_offset: 0},
        session_id: 123,
        last_msg_id: 100
      )

    body = bad_server_salt_body(800, 3, 48, -999)

    assert {:ok, encrypted} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: 42,
                 session_id: 123,
                 message_id: 5_000,
                 seq_no: 1,
                 body: body
               },
               auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    assert {:ok, next_session, effects} =
             Session.receive_packet(session, encrypted, 9_000_000_000,
               padding_bytes: :binary.copy(<<0xCC>>, 64)
             )

    assert next_session.server_salt == -999

    assert {:send_encrypted, ack_payload} =
             Enum.find(effects, fn
               {:send_encrypted, _payload} -> true
               _ -> false
             end)

    assert {:ok, ack_packet} =
             EncryptedPacket.decode(ack_payload, auth_key,
               sender: :client,
               session_id: 123
             )

    assert ack_packet.salt == -999
    assert ack_packet.seq_no == 0
    assert ack_packet.body == msgs_ack_body([5_000])

    assert {:bad_server_salt, 800, 3, 48, -999} in notifications(effects)

    assert {:msgs_ack_sent, ack_packet.message_id, [5_000]} in notifications(
             effects
           )
  end

  test "tracks content requests and correlates rpc_result replies" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    {:ok, session} =
      Session.new(
        %ExchangeResult{auth_key: auth_key, server_salt: 42, time_offset: 0},
        session_id: 123,
        last_msg_id: 100
      )

    request_body = <<0x44, 0x33, 0x22, 0x11>>

    assert {:ok, requested_session, request_id, send_effects} =
             Session.send_request(session, 2_000_000_000, request_body,
               request: :demo_request,
               padding_bytes: :binary.copy(<<0xAA>>, 64)
             )

    assert requested_session.sent_content_messages == 1

    assert requested_session.pending_requests[request_id] == %{
             body: request_body,
             request: :demo_request,
             seq_no: 1
           }

    assert {:ok, encrypted} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: 42,
                 session_id: 123,
                 message_id: 5_000,
                 seq_no: 1,
                 body: rpc_result_body(request_id, <<0x88, 0x77, 0x66, 0x55>>)
               },
               auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    assert {:ok, next_session, receive_effects} =
             Session.receive_packet(
               requested_session,
               encrypted,
               9_000_000_000,
               padding_bytes: :binary.copy(<<0xCC>>, 64)
             )

    assert next_session.pending_requests == %{}

    assert {:rpc_request_sent, request_id, :demo_request} in notifications(
             send_effects
           )

    assert {:rpc_result, request_id, <<0x88, 0x77, 0x66, 0x55>>} in notifications(
             receive_effects
           )

    assert {:rpc_request_result, request_id, :demo_request,
            <<0x88, 0x77, 0x66, 0x55>>} in notifications(receive_effects)

    assert {:send_encrypted, ack_payload} =
             Enum.find(receive_effects, fn
               {:send_encrypted, _payload} -> true
               _ -> false
             end)

    assert {:ok, ack_packet} =
             EncryptedPacket.decode(ack_payload, auth_key,
               sender: :client,
               session_id: 123
             )

    assert ack_packet.seq_no == 2
    assert ack_packet.body == msgs_ack_body([5_000])
  end

  test "resends a pending request after bad_server_salt" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    {:ok, session} =
      Session.new(
        %ExchangeResult{auth_key: auth_key, server_salt: 42, time_offset: 0},
        session_id: 123,
        last_msg_id: 100
      )

    request_body = <<0x10, 0x20, 0x30, 0x40>>

    assert {:ok, requested_session, request_id, _send_effects} =
             Session.send_request(session, 2_000_000_000, request_body,
               request: :salt_sensitive,
               padding_bytes: :binary.copy(<<0xAA>>, 64)
             )

    assert {:ok, encrypted} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: 42,
                 session_id: 123,
                 message_id: 5_500,
                 seq_no: 1,
                 body: bad_server_salt_body(request_id, 1, 48, -999)
               },
               auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    assert {:ok, next_session, receive_effects} =
             Session.receive_packet(
               requested_session,
               encrypted,
               9_000_000_000,
               padding_bytes: :binary.copy(<<0xCC>>, 128)
             )

    assert next_session.server_salt == -999
    assert Map.has_key?(next_session.pending_requests, request_id)

    [resent_effect, ack_effect] =
      Enum.filter(receive_effects, fn
        {:send_encrypted, _payload} -> true
        _ -> false
      end)

    {:send_encrypted, resent_payload} = resent_effect
    {:send_encrypted, ack_payload} = ack_effect

    assert {:ok, resent_packet} =
             EncryptedPacket.decode(resent_payload, auth_key,
               sender: :client,
               session_id: 123
             )

    assert resent_packet.salt == -999
    assert resent_packet.message_id == request_id
    assert resent_packet.seq_no == 1
    assert resent_packet.body == request_body

    assert {:ok, ack_packet} =
             EncryptedPacket.decode(ack_payload, auth_key,
               sender: :client,
               session_id: 123
             )

    assert ack_packet.salt == -999
    assert ack_packet.seq_no == 2
    assert ack_packet.body == msgs_ack_body([5_500])

    assert {:rpc_request_resent, request_id, :salt_sensitive, -999} in notifications(
             receive_effects
           )
  end

  test "unwraps message containers and emits the contained service messages" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    {:ok, session} =
      Session.new(
        %ExchangeResult{auth_key: auth_key, server_salt: 42, time_offset: 0},
        session_id: 123,
        last_msg_id: 100
      )

    body =
      message_container_body([
        %{
          message_id: 700,
          seq_no: 0,
          body: new_session_created_body(111, 222, 555)
        },
        %{message_id: 704, seq_no: 0, body: pong_body(444, 99)},
        %{message_id: 708, seq_no: 0, body: msgs_ack_body([333, 444])},
        %{
          message_id: 712,
          seq_no: 0,
          body: rpc_result_body(999, ping_body(77))
        }
      ])

    assert {:ok, encrypted} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: 42,
                 session_id: 123,
                 message_id: 6_000,
                 seq_no: 1,
                 body: body
               },
               auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xDD>>, 64)
             )

    assert {:ok, next_session, effects} =
             Session.receive_packet(session, encrypted, 12_000_000_000,
               padding_bytes: :binary.copy(<<0xEE>>, 64)
             )

    assert next_session.server_salt == 555

    notes = notifications(effects)

    assert {:new_session_created, 111, 222, 555} in notes
    assert {:pong, 444, 99} in notes
    assert {:msgs_ack, [333, 444]} in notes
    assert {:rpc_result, 999, ping_body(77)} in notes
  end

  defp notifications(effects) do
    for {:notify, event} <- effects, do: event
  end

  defp ping_body(ping_id) do
    <<0x7ABE77EC::little-unsigned-32, ping_id::little-signed-64>>
  end

  defp pong_body(msg_id, ping_id) do
    <<0x347773C5::little-unsigned-32, msg_id::little-signed-64,
      ping_id::little-signed-64>>
  end

  defp msgs_ack_body(msg_ids) do
    <<0x62D6B459::little-unsigned-32,
      TL.encode_vector(msg_ids, &TL.encode_signed_long/1)::binary>>
  end

  defp new_session_created_body(first_msg_id, unique_id, server_salt) do
    <<0x9EC20908::little-unsigned-32, first_msg_id::little-signed-64,
      unique_id::little-signed-64, server_salt::little-signed-64>>
  end

  defp bad_server_salt_body(
         bad_msg_id,
         bad_msg_seq_no,
         error_code,
         new_server_salt
       ) do
    <<0xEDAB447B::little-unsigned-32, bad_msg_id::little-signed-64,
      bad_msg_seq_no::little-signed-32, error_code::little-signed-32,
      new_server_salt::little-signed-64>>
  end

  defp rpc_result_body(req_msg_id, result) do
    <<0xF35C6D01::little-unsigned-32, req_msg_id::little-signed-64,
      result::binary>>
  end

  defp message_container_body(messages) do
    entries =
      Enum.map_join(messages, fn %{
                                   message_id: message_id,
                                   seq_no: seq_no,
                                   body: body
                                 } ->
        <<message_id::little-signed-64, seq_no::little-signed-32,
          byte_size(body)::little-signed-32, body::binary>>
      end)

    <<0x73F1F8DC::little-unsigned-32, length(messages)::little-signed-32,
      entries::binary>>
  end
end
