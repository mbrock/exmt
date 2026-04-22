defmodule MTProto.Telegram.ClientTest do
  use ExUnit.Case, async: true

  alias MTProto.{
    EncryptedPacket,
    SessionData,
    TL,
    Transport.Abridged
  }

  alias MTProto.Telegram.{API, Client}
  alias MTProto.TL.Runtime.Decoded

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

  test "telegram client decodes rpc_error results for typed API requests" do
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

    assert_receive {:telegram, ^client,
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

  test "telegram client sends auth.sendCode and emits decoded auth.sentCode results" do
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

    assert_receive {:telegram, ^client,
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
        session_data: session_data,
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
        session_id: 123,
        now_ns_fun: fn -> 1_713_534_000_000_000_000 end
      )

    socket = {:fake_socket, self()}

    assert_receive {:fake_socket, :connect, ~c"149.154.167.50", 443, _opts}
    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}
    assert_receive {:mtproto, ^client, {:session_data_updated, ^session_data}}
    assert_receive {:mtproto, ^client, {:session_ready, 123}}

    %{client: client, socket: socket, session_data: session_data}
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

  defp mtproto_connection(client) do
    mtproto_client = :sys.get_state(client).mtproto_client
    :sys.get_state(mtproto_client).connection
  end

  defp decode_transport_frame(packet) do
    with {:ok, _decoder, [frame]} <-
           Abridged.feed(Abridged.new_decoder(), packet) do
      {:ok, frame}
    end
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
      mtproto_connection(client),
      {:tcp, socket, Abridged.encode(server_payload)}
    )
  end
end
