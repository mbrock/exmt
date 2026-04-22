defmodule MTProto.ClientTest do
  use ExUnit.Case, async: true

  alias MTProto.API
  alias MTProto.TL
  alias MTProto.TL.Runtime.Decoded
  alias MTProto.Auth.PublicKey

  alias MTProto.{
    Client,
    EncryptedPacket,
    PlainMessage,
    SessionData,
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

  defmodule FakeSessionStore do
    @behaviour MTProto.SessionStore

    @impl true
    def load(%{test_pid: test_pid, name: name, load: result}) do
      send(test_pid, {:fake_store, :load, name})
      {:ok, result}
    end

    @impl true
    def save(
          %{test_pid: test_pid, name: name, save: save_result},
          session_data
        ) do
      send(test_pid, {:fake_store, :save, name, session_data})
      save_result
    end

    @impl true
    def delete(%{test_pid: test_pid, name: name, delete: delete_result}) do
      send(test_pid, {:fake_store, :delete, name})
      delete_result
    end
  end

  test "client restores session data from the configured store" do
    session_data = sample_session_data(dc_id: 2)

    {:ok, client} =
      Client.start_link(
        host: ~c"149.154.167.50",
        port: 443,
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
        session_store: {FakeSessionStore, store_key(load: session_data)},
        session_id: 123,
        now_ns_fun: fn -> 1_713_534_000_000_000_000 end
      )

    socket = {:fake_socket, self()}

    assert_receive {:fake_store, :load, :default}
    assert_receive {:fake_socket, :connect, ~c"149.154.167.50", 443, _opts}
    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}
    assert_receive {:mtproto, ^client, {:session_data_updated, ^session_data}}
    assert_receive {:mtproto, ^client, {:session_ready, 123}}

    assert Client.session_data(client) == session_data

    assert :ok =
             Client.ping(client, 99,
               padding_bytes: :binary.copy(<<0xAA>>, 64)
             )

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, ping_packet}

    assert {:ok, ping_payload} = decode_transport_frame(ping_packet)

    assert {:ok, decoded_ping_packet} =
             EncryptedPacket.decode(
               ping_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    assert decoded_ping_packet.salt == session_data.server_salt
    assert decoded_ping_packet.body == ping_body(99)
  end

  test "client persists updated session data when the server changes salt" do
    %{client: client, socket: socket, session_data: session_data} =
      start_restored_client()

    assert :ok =
             Client.ping(client, 99,
               padding_bytes: :binary.copy(<<0xAA>>, 64)
             )

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, ping_packet}

    assert {:ok, ping_payload} = decode_transport_frame(ping_packet)

    assert {:ok, decoded_ping_packet} =
             EncryptedPacket.decode(
               ping_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    server_body =
      message_container_body([
        %{
          message_id: 701,
          seq_no: 0,
          body: new_session_created_body(111, 222, 555)
        },
        %{
          message_id: 705,
          seq_no: 0,
          body: pong_body(decoded_ping_packet.message_id, 99)
        }
      ])

    assert {:ok, server_payload} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: session_data.server_salt,
                 session_id: 123,
                 message_id: 7_000,
                 seq_no: 1,
                 body: server_body
               },
               SessionData.auth_key(session_data),
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    send(
      client_connection(client),
      {:tcp, socket, Abridged.encode(server_payload)}
    )

    assert_receive {:mtproto, ^client,
                    {:session_data_updated,
                     %SessionData{server_salt: 555} = updated_session_data}}

    assert_receive {:fake_store, :save, :default, ^updated_session_data}
    assert Client.session_data(client) == updated_session_data
  end

  test "client saves newly-created session data after auth" do
    %{client: client, socket: socket} = start_client_for_auth()

    assert :ok =
             Client.begin_auth_key_exchange(client,
               nonce: MTProto.AuthExchangeSample.step1_nonce()
             )

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, initial_packet}
    assert_receive {:mtproto, ^client, {:request_sent, :req_pq_multi}}

    assert_plain_packet_body(
      initial_packet,
      MTProto.AuthExchangeSample.step1_request()
    )

    send(
      client_connection(client),
      {:tcp, socket,
       encode_plain_frame(MTProto.AuthExchangeSample.step1_response(), 1)}
    )

    assert_receive {:fake_socket, :send, ^socket, step2_packet}

    assert_plain_packet_body(
      step2_packet,
      MTProto.AuthExchangeSample.step2_request()
    )

    send(
      client_connection(client),
      {:tcp, socket,
       encode_plain_frame(MTProto.AuthExchangeSample.step2_response(), 2)}
    )

    assert_receive {:fake_socket, :send, ^socket, step3_packet}

    assert_plain_packet_body(
      step3_packet,
      MTProto.AuthExchangeSample.step3_request()
    )

    send(
      client_connection(client),
      {:tcp, socket,
       encode_plain_frame(MTProto.AuthExchangeSample.step3_response(), 3)}
    )

    assert_receive {:mtproto, ^client, {:auth_key_created, result}}

    assert_receive {:mtproto, ^client,
                    {:session_data_updated, %SessionData{} = session_data}}

    assert_receive {:fake_store, :save, :default, ^session_data}
    assert_receive {:mtproto, ^client, {:session_ready, 123}}

    assert result.auth_key.data == session_data.auth_key_data
    assert result.server_salt == session_data.server_salt
    assert result.time_offset == session_data.time_offset
    assert session_data.dc_id == 0
  end

  test "client decodes rpc_error results for typed API requests" do
    %{client: client, socket: socket, session_data: session_data} =
      start_restored_client()

    opts = [
      api_id: 12345,
      device_model: "exmt-dev",
      system_version: "OTP test",
      app_version: "0.1.0-test",
      system_lang_code: "en",
      lang_pack: "",
      lang_code: "en",
      padding_bytes: :binary.copy(<<0xAA>>, 64)
    ]

    assert {:ok, request_id} = Client.get_config(client, opts)
    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert_receive {:mtproto, ^client,
                    {:rpc_request_sent, ^request_id, :help_get_config}}

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(
               request_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    assert {:ok, expected_body} =
             API.wrap_request(API.help_get_config(), opts)

    assert decoded_request_packet.body == expected_body

    response_body = rpc_error_body(420, "FLOOD_WAIT_1")

    send_encrypted_server_result(
      client,
      socket,
      session_data,
      rpc_result_body(request_id, response_body),
      8_000
    )

    assert_receive {:mtproto, ^client,
                    {:rpc_result, ^request_id, ^response_body}}

    assert_receive {:mtproto, ^client,
                    {:rpc_request_error, ^request_id, :help_get_config,
                     ^response_body,
                     %Decoded{
                       tl_name: "rpc_error",
                       type_name: "RpcError",
                       fields: %{
                         error_code: 420,
                         error_message: "FLOOD_WAIT_1"
                       }
                     }}}
  end

  test "client sends auth.sendCode and emits decoded auth.sentCode results" do
    %{client: client, socket: socket, session_data: session_data} =
      start_restored_client()

    opts = [
      api_id: 12345,
      device_model: "exmt-dev",
      system_version: "OTP test",
      app_version: "0.1.0-test",
      system_lang_code: "en",
      lang_pack: "",
      lang_code: "en",
      settings: [allow_app_hash: true],
      padding_bytes: :binary.copy(<<0xAA>>, 64)
    ]

    assert {:ok, request_id} =
             Client.send_code(client, "+15551234567", "hash-123", opts)

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert_receive {:mtproto, ^client,
                    {:rpc_request_sent, ^request_id, :auth_send_code}}

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(
               request_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    assert {:ok, query} =
             API.auth_send_code("+15551234567", "hash-123", opts)

    assert {:ok, expected_body} = API.wrap_request(query, opts)
    assert decoded_request_packet.body == expected_body

    response_body = sent_code_body("phone-code-hash", 6)

    send_encrypted_server_result(
      client,
      socket,
      session_data,
      rpc_result_body(request_id, response_body),
      9_000
    )

    assert_receive {:mtproto, ^client,
                    {:rpc_request_result_decoded, ^request_id,
                     :auth_send_code, ^response_body,
                     %Decoded{
                       tl_name: "auth.sentCode",
                       type_name: "auth.SentCode",
                       fields: %{
                         phone_code_hash: "phone-code-hash",
                         next_type: nil,
                         timeout: nil,
                         type: %Decoded{
                           tl_name: "auth.sentCodeTypeApp",
                           fields: %{length: 6}
                         }
                       }
                     }}}
  end

  defp start_restored_client do
    session_data = sample_session_data(dc_id: 2)

    {:ok, client} =
      Client.start_link(
        host: ~c"149.154.167.50",
        port: 443,
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
        session_store: {FakeSessionStore, store_key(load: session_data)},
        session_id: 123,
        now_ns_fun: fn -> 1_713_534_000_000_000_000 end
      )

    socket = {:fake_socket, self()}

    assert_receive {:fake_store, :load, :default}
    assert_receive {:fake_socket, :connect, ~c"149.154.167.50", 443, _opts}
    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}
    assert_receive {:mtproto, ^client, {:session_data_updated, ^session_data}}
    assert_receive {:mtproto, ^client, {:session_ready, 123}}

    %{client: client, socket: socket, session_data: session_data}
  end

  defp start_client_for_auth do
    {:ok, key} = PublicKey.from_pem(MTProto.TelegramKeys.sample_pem())

    {:ok, client} =
      Client.start_link(
        host: ~c"149.154.167.40",
        port: 443,
        public_keys: [key],
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
        session_store: {FakeSessionStore, store_key(load: nil)},
        session_id: 123,
        random_bytes_chunks: [
          MTProto.AuthExchangeSample.step2_random(),
          MTProto.AuthExchangeSample.step3_random()
        ],
        now_ns_fun: fn -> 1_713_534_000_000_000_000 end,
        now_sec_fun: fn -> MTProto.AuthExchangeSample.step3_now() end
      )

    socket = {:fake_socket, self()}

    assert_receive {:fake_store, :load, :default}
    assert_receive {:fake_socket, :connect, ~c"149.154.167.40", 443, _opts}
    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}

    %{client: client, socket: socket}
  end

  defp client_connection(client) do
    :sys.get_state(client).connection
  end

  defp store_key(opts) do
    %{
      test_pid: self(),
      name: :default,
      load: Keyword.get(opts, :load),
      save: Keyword.get(opts, :save, :ok),
      delete: Keyword.get(opts, :delete, :ok)
    }
  end

  defp sample_session_data(opts) do
    SessionData.new!(
      Keyword.merge(
        [
          auth_key_data: MTProto.AuthExchangeSample.expected_auth_key(),
          server_salt: MTProto.AuthExchangeSample.expected_server_salt(),
          time_offset: MTProto.AuthExchangeSample.expected_time_offset(),
          dc_id: 0
        ],
        opts
      )
    )
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

  defp rpc_error_body(error_code, error_message) do
    <<0x2144CA19::little-unsigned-32, TL.encode_int(error_code)::binary,
      TL.encode_bytes(error_message)::binary>>
  end

  defp sent_code_body(phone_code_hash, length) do
    <<0x5E002502::little-unsigned-32, TL.encode_int(0)::binary,
      0x3DBB5986::little-unsigned-32, TL.encode_int(length)::binary,
      TL.encode_bytes(phone_code_hash)::binary>>
  end

  defp pong_body(msg_id, ping_id) do
    <<0x347773C5::little-unsigned-32, msg_id::little-signed-64,
      ping_id::little-signed-64>>
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

  defp send_encrypted_server_result(
         client,
         socket,
         session_data,
         body,
         message_id
       ) do
    assert {:ok, server_payload} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: session_data.server_salt,
                 session_id: 123,
                 message_id: message_id,
                 seq_no: 1,
                 body: body
               },
               SessionData.auth_key(session_data),
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    send(
      client_connection(client),
      {:tcp, socket, Abridged.encode(server_payload)}
    )
  end
end
