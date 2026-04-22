defmodule MTProto.TCPConnectionTest do
  use ExUnit.Case, async: true

  alias MTProto.Auth.PublicKey

  alias MTProto.{
    API,
    EncryptedPacket,
    PlainMessage,
    TCPConnection,
    TL,
    Transport.Abridged
  }

  defmodule FakeSocket do
    @behaviour MTProto.Socket

    @impl true
    def connect(host, port, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      Kernel.send(test_pid, {:fake_socket, :connect, host, port, opts})
      {:ok, {:fake_socket, test_pid}}
    end

    @impl true
    def send({:fake_socket, test_pid} = socket, data) do
      Kernel.send(
        test_pid,
        {:fake_socket, :send, socket, IO.iodata_to_binary(data)}
      )

      :ok
    end

    @impl true
    def setopts({:fake_socket, test_pid} = socket, opts) do
      Kernel.send(test_pid, {:fake_socket, :setopts, socket, opts})
      :ok
    end

    @impl true
    def close({:fake_socket, test_pid} = socket) do
      Kernel.send(test_pid, {:fake_socket, :close, socket})
      :ok
    end
  end

  test "TCP connection completes auth, starts a session, and exchanges an encrypted ping" do
    %{connection: connection, socket: socket, result: result} =
      start_authenticated_connection()

    assert :ok =
             TCPConnection.ping(connection, 99,
               padding_bytes: :binary.copy(<<0xAA>>, 64)
             )

    assert_receive {:fake_socket, :send, ^socket, ping_packet}

    assert_receive {:mtproto, ^connection,
                    {:encrypted_packet_sent, sent_packet}}

    assert_receive {:mtproto, ^connection,
                    {:session_message_sent, ping_msg_id, 0, ping_body}}

    assert_receive {:mtproto, ^connection, {:ping_sent, ^ping_msg_id, 99}}

    assert ping_body == ping_body(99)

    assert {:ok, ping_payload} = decode_transport_frame(ping_packet)

    assert {:ok, decoded_ping_packet} =
             EncryptedPacket.decode(ping_payload, result.auth_key,
               sender: :client,
               session_id: 123
             )

    assert decoded_ping_packet == sent_packet
    assert decoded_ping_packet.body == ping_body(99)
    assert decoded_ping_packet.seq_no == 0

    server_body =
      message_container_body([
        %{
          message_id: 701,
          seq_no: 0,
          body: new_session_created_body(111, 222, 555)
        },
        %{message_id: 705, seq_no: 0, body: pong_body(ping_msg_id, 99)}
      ])

    assert {:ok, server_payload} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: result.server_salt,
                 session_id: 123,
                 message_id: 7_000,
                 seq_no: 1,
                 body: server_body
               },
               result.auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    send(connection, {:tcp, socket, Abridged.encode(server_payload)})

    assert_receive {:mtproto, ^connection,
                    {:encrypted_packet_received, _packet}}

    assert_receive {:mtproto, ^connection,
                    {:new_session_created, 111, 222, 555}}

    assert_receive {:mtproto, ^connection, {:pong, ^ping_msg_id, 99}}

    assert_receive {:fake_socket, :send, ^socket, ack_packet}

    assert_receive {:mtproto, ^connection,
                    {:msgs_ack_sent, ack_msg_id, [7_000]}}

    assert {:ok, ack_payload} = decode_transport_frame(ack_packet)

    assert {:ok, ack_plaintext} =
             EncryptedPacket.decode(ack_payload, result.auth_key,
               sender: :client,
               session_id: 123
             )

    assert ack_plaintext.message_id == ack_msg_id
    assert ack_plaintext.salt == 555
    assert ack_plaintext.seq_no == 0
    assert ack_plaintext.body == msgs_ack_body([7_000])

    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}
  end

  test "TCP connection sends raw RPC requests and correlates rpc_result" do
    %{connection: connection, socket: socket, result: result} =
      start_authenticated_connection()

    request_body = <<0x44, 0x33, 0x22, 0x11>>
    response_body = <<0x88, 0x77, 0x66, 0x55>>

    assert {:ok, request_id} =
             TCPConnection.invoke(connection, request_body,
               request: :demo_request,
               padding_bytes: :binary.copy(<<0xAA>>, 64)
             )

    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert_receive {:mtproto, ^connection,
                    {:encrypted_packet_sent, sent_packet}}

    assert_receive {:mtproto, ^connection,
                    {:session_message_sent, ^request_id, 1, ^request_body}}

    assert_receive {:mtproto, ^connection,
                    {:rpc_request_sent, ^request_id, :demo_request}}

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(request_payload, result.auth_key,
               sender: :client,
               session_id: 123
             )

    assert decoded_request_packet == sent_packet
    assert decoded_request_packet.body == request_body
    assert decoded_request_packet.seq_no == 1

    assert {:ok, server_payload} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: result.server_salt,
                 session_id: 123,
                 message_id: 8_000,
                 seq_no: 1,
                 body: rpc_result_body(request_id, response_body)
               },
               result.auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    send(connection, {:tcp, socket, Abridged.encode(server_payload)})

    assert_receive {:mtproto, ^connection,
                    {:encrypted_packet_received, _packet}}

    assert_receive {:mtproto, ^connection,
                    {:rpc_result, ^request_id, ^response_body}}

    assert_receive {:mtproto, ^connection,
                    {:rpc_request_result, ^request_id, :demo_request,
                     ^response_body}}

    assert_receive {:fake_socket, :send, ^socket, ack_packet}

    assert_receive {:mtproto, ^connection,
                    {:msgs_ack_sent, ack_msg_id, [8_000]}}

    assert {:ok, ack_payload} = decode_transport_frame(ack_packet)

    assert {:ok, ack_plaintext} =
             EncryptedPacket.decode(ack_payload, result.auth_key,
               sender: :client,
               session_id: 123
             )

    assert ack_plaintext.message_id == ack_msg_id
    assert ack_plaintext.seq_no == 2
    assert ack_plaintext.body == msgs_ack_body([8_000])
  end

  test "TCP connection builds and sends help.getConfig API calls" do
    %{connection: connection, socket: socket, result: result} =
      start_authenticated_connection()

    opts = [
      api_id: 12345,
      device_model: "exmt-dev",
      system_version: "OTP test",
      app_version: "0.1.0-test",
      system_lang_code: "en",
      lang_pack: "",
      lang_code: "en",
      layer: 214,
      padding_bytes: :binary.copy(<<0xAA>>, 64)
    ]

    assert {:ok, request_id} = TCPConnection.get_config(connection, opts)
    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert_receive {:mtproto, ^connection,
                    {:encrypted_packet_sent, sent_packet}}

    assert_receive {:mtproto, ^connection,
                    {:session_message_sent, ^request_id, 1, request_body}}

    assert_receive {:mtproto, ^connection,
                    {:rpc_request_sent, ^request_id, :help_get_config}}

    assert {:ok, expected_body} =
             API.wrap_request(API.help_get_config(), opts)

    assert request_body == expected_body

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(request_payload, result.auth_key,
               sender: :client,
               session_id: 123
             )

    assert decoded_request_packet == sent_packet
    assert decoded_request_packet.body == expected_body

    response_body = <<0xCC, 0xBB, 0xAA, 0x99>>

    assert {:ok, server_payload} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: result.server_salt,
                 session_id: 123,
                 message_id: 9_000,
                 seq_no: 1,
                 body: rpc_result_body(request_id, response_body)
               },
               result.auth_key,
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    send(connection, {:tcp, socket, Abridged.encode(server_payload)})

    assert_receive {:mtproto, ^connection,
                    {:rpc_request_result, ^request_id, :help_get_config,
                     ^response_body}}
  end

  defp encode_plain_frame(body, message_id) do
    %PlainMessage{message_id: message_id, body: body}
    |> PlainMessage.encode()
    |> Abridged.encode()
  end

  defp assert_plain_packet_body(packet, expected_body) do
    assert {:ok, frame} = decode_transport_frame(packet)
    assert {:ok, message} = PlainMessage.decode(frame)
    assert message.body == expected_body
  end

  defp decode_transport_frame(packet) do
    with {:ok, _decoder, [frame]} <-
           Abridged.feed(Abridged.new_decoder(), packet) do
      {:ok, frame}
    end
  end

  defp ping_body(ping_id) do
    <<0x7ABE77EC::little-unsigned-32, ping_id::little-signed-64>>
  end

  defp rpc_result_body(req_msg_id, result) do
    <<0xF35C6D01::little-unsigned-32, req_msg_id::little-signed-64,
      result::binary>>
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

  defp start_authenticated_connection do
    {:ok, key} = PublicKey.from_pem(MTProto.TelegramKeys.sample_pem())

    {:ok, connection} =
      TCPConnection.start_link(
        host: ~c"149.154.167.40",
        port: 443,
        public_keys: [key],
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
        session_id: 123,
        random_bytes_chunks: [
          MTProto.AuthExchangeSample.step2_random(),
          MTProto.AuthExchangeSample.step3_random()
        ],
        now_ns_fun: fn -> 1_713_534_000_000_000_000 end,
        now_sec_fun: fn -> MTProto.AuthExchangeSample.step3_now() end
      )

    socket = {:fake_socket, self()}

    assert_receive {:fake_socket, :connect, ~c"149.154.167.40", 443, _opts}
    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}

    assert :ok =
             TCPConnection.begin_auth_key_exchange(connection,
               nonce: MTProto.AuthExchangeSample.step1_nonce()
             )

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, initial_packet}
    assert_receive {:mtproto, ^connection, {:request_sent, :req_pq_multi}}

    assert_receive {:mtproto, ^connection,
                    {:plain_message_sent, initial_msg_id, initial_body}}

    assert is_integer(initial_msg_id)
    assert initial_body == MTProto.AuthExchangeSample.step1_request()

    assert_plain_packet_body(
      initial_packet,
      MTProto.AuthExchangeSample.step1_request()
    )

    send(
      connection,
      {:tcp, socket,
       encode_plain_frame(MTProto.AuthExchangeSample.step1_response(), 1)}
    )

    assert_receive {:mtproto, ^connection, {:plain_message_received, 1, body}}
    assert body == MTProto.AuthExchangeSample.step1_response()
    assert_receive {:fake_socket, :send, ^socket, step2_packet}
    assert_receive {:mtproto, ^connection, {:res_pq, _res_pq}}

    assert_receive {:mtproto, ^connection,
                    {:plain_message_sent, _msg_id, step2_body}}

    assert step2_body == MTProto.AuthExchangeSample.step2_request()

    assert_plain_packet_body(
      step2_packet,
      MTProto.AuthExchangeSample.step2_request()
    )

    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}

    send(
      connection,
      {:tcp, socket,
       encode_plain_frame(MTProto.AuthExchangeSample.step2_response(), 2)}
    )

    assert_receive {:mtproto, ^connection, {:plain_message_received, 2, body}}
    assert body == MTProto.AuthExchangeSample.step2_response()
    assert_receive {:fake_socket, :send, ^socket, step3_packet}

    assert_receive {:mtproto, ^connection,
                    {:server_dh_inner_data, inner_data}}

    assert inner_data.server_time == MTProto.AuthExchangeSample.step3_now()

    assert_receive {:mtproto, ^connection,
                    {:plain_message_sent, _msg_id, step3_body}}

    assert step3_body == MTProto.AuthExchangeSample.step3_request()

    assert_plain_packet_body(
      step3_packet,
      MTProto.AuthExchangeSample.step3_request()
    )

    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}

    send(
      connection,
      {:tcp, socket,
       encode_plain_frame(MTProto.AuthExchangeSample.step3_response(), 3)}
    )

    assert_receive {:mtproto, ^connection, {:plain_message_received, 3, body}}
    assert body == MTProto.AuthExchangeSample.step3_response()

    assert_receive {:mtproto, ^connection, {:auth_key_created, result}}
    assert_receive {:mtproto, ^connection, {:session_ready, 123}}

    assert result.auth_key.data ==
             MTProto.AuthExchangeSample.expected_auth_key()

    assert result.server_salt ==
             MTProto.AuthExchangeSample.expected_server_salt()

    assert result.time_offset ==
             MTProto.AuthExchangeSample.expected_time_offset()

    %{connection: connection, socket: socket, result: result}
  end
end
