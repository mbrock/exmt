defmodule MTProto.Telegram.ConnectionTest do
  use ExUnit.Case, async: true

  alias MTProto.{
    EncryptedPacket,
    SessionData,
    Transport.Abridged
  }

  alias MTProto.Telegram.{API, Connection, UpdateState}
  alias MTProto.Telegram.UpdateStateStore.File, as: UpdateStateFileStore
  alias MTProto.TL.Encoder
  alias MTProto.TL.Runtime.Decoded
  alias MTProto.TL.Schema.Registry

  defmodule FakeSocket do
    @behaviour MTProto.Socket

    @impl true
    def connect(host, port, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      owner = self()
      socket_pid = spawn_link(fn -> socket_loop(owner, test_pid) end)
      socket = {:fake_socket, socket_pid, test_pid}

      Kernel.send(
        test_pid,
        {:fake_socket, :connect, host, port, socket, opts}
      )

      {:ok, socket}
    end

    @impl true
    def send({:fake_socket, _socket_pid, test_pid} = socket, data) do
      Kernel.send(
        test_pid,
        {:fake_socket, :send, socket, IO.iodata_to_binary(data)}
      )

      :ok
    end

    @impl true
    def setopts({:fake_socket, _socket_pid, test_pid} = socket, opts) do
      Kernel.send(test_pid, {:fake_socket, :setopts, socket, opts})
      :ok
    end

    @impl true
    def close({:fake_socket, socket_pid, test_pid} = socket) do
      Kernel.send(socket_pid, :close)
      Kernel.send(test_pid, {:fake_socket, :close, socket})
      :ok
    end

    defp socket_loop(owner, test_pid) do
      receive do
        {:deliver, data} ->
          Kernel.send(owner, {:tcp, {:fake_socket, self(), test_pid}, data})
          socket_loop(owner, test_pid)

        :close ->
          :ok
      end
    end
  end

  test "connection bootstraps from updates.getState when no stored state exists" do
    request_opts = request_opts()
    update_state_path = temp_update_state_path()

    %{connection: connection, socket: socket, session_data: session_data} =
      start_connection(update_state_path)

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(
               request_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    assert {:ok, expected_body} =
             API.wrap_request(API.Updates.getState(), request_opts)

    assert decoded_request_packet.body == expected_body

    send_encrypted_server_result(
      socket,
      session_data,
      rpc_result_body(
        decoded_request_packet.message_id,
        encode_constructor!("updates.state",
          pts: 11,
          qts: 22,
          date: 33,
          seq: 44,
          unread_count: 55
        )
      ),
      8_000
    )

    assert {:ok,
            %{
              session_id: 123,
              source: :fetched,
              update_state:
                %UpdateState{
                  pts: 11,
                  qts: 22,
                  date: 33,
                  seq: 44,
                  unread_count: 55
                } = update_state
            }} = Connection.await_ready(connection)

    assert_receive {:telegram_connection, ^connection,
                    {:ready, 123, ^update_state, :fetched}}

    assert Connection.update_state(connection) == update_state
    assert {:ok, ^update_state} = UpdateStateFileStore.load(update_state_path)
  end

  test "connection reconciles stored state with updates.getDifference on startup" do
    request_opts = request_opts()
    update_state_path = temp_update_state_path()

    stored_state = UpdateState.new!(pts: 10, qts: 20, date: 30, seq: 40)
    assert :ok = UpdateStateFileStore.save(update_state_path, stored_state)

    %{connection: connection, socket: socket, session_data: session_data} =
      start_connection(update_state_path)

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(
               request_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    assert {:ok, expected_body} =
             API.wrap_request(
               API.Updates.getDifference(
                 pts: stored_state.pts,
                 date: stored_state.date,
                 qts: stored_state.qts
               ),
               request_opts
             )

    assert decoded_request_packet.body == expected_body

    send_encrypted_server_result(
      socket,
      session_data,
      rpc_result_body(
        decoded_request_packet.message_id,
        encode_constructor!("updates.differenceEmpty", date: 31, seq: 41)
      ),
      8_000
    )

    assert {:ok,
            %{
              session_id: 123,
              source: :stored,
              update_state:
                %UpdateState{
                  pts: 10,
                  qts: 20,
                  date: 31,
                  seq: 41
                } = update_state
            }} = Connection.await_ready(connection)

    assert_receive {:telegram_connection, ^connection,
                    {:difference,
                     %{
                       state: ^update_state,
                       items: [],
                       final?: true
                     }}}

    assert {:ok, ^update_state} = UpdateStateFileStore.load(update_state_path)
  end

  test "connection applies pushed updates and advances durable state" do
    update_state_path = temp_update_state_path()

    %{connection: connection, socket: socket, session_data: session_data} =
      start_connection(update_state_path)

    assert_receive {:fake_socket, :send, ^socket, <<0xEF>>}
    assert_receive {:fake_socket, :send, ^socket, request_packet}

    assert {:ok, request_payload} = decode_transport_frame(request_packet)

    assert {:ok, decoded_request_packet} =
             EncryptedPacket.decode(
               request_payload,
               SessionData.auth_key(session_data),
               sender: :client,
               session_id: 123
             )

    send_encrypted_server_result(
      socket,
      session_data,
      rpc_result_body(
        decoded_request_packet.message_id,
        encode_constructor!("updates.state",
          pts: 1,
          qts: 2,
          date: 3,
          seq: 4,
          unread_count: 5
        )
      ),
      8_000
    )

    assert {:ok, %{update_state: initial_state}} =
             Connection.await_ready(connection)

    assert initial_state ==
             UpdateState.new!(
               pts: 1,
               qts: 2,
               date: 3,
               seq: 4,
               unread_count: 5
             )

    send_encrypted_server_message(
      socket,
      session_data,
      encode_constructor!("updateShortMessage",
        id: 99,
        user_id: 42,
        message: "hello",
        pts: 11,
        pts_count: 1,
        date: 33
      ),
      9_000
    )

    assert_receive {:telegram_connection, ^connection,
                    {:update,
                     %{
                       state:
                         %UpdateState{
                           pts: 11,
                           qts: 2,
                           date: 33,
                           seq: 4
                         } = update_state,
                       top_level: %Decoded{
                         tl_name: "updateShortMessage",
                         type_name: "Updates"
                       }
                     }}}

    assert Connection.update_state(connection) == update_state
    assert {:ok, ^update_state} = UpdateStateFileStore.load(update_state_path)
  end

  defp start_connection(update_state_path) do
    session_data = sample_session_data(dc_id: 2)

    {:ok, connection} =
      Connection.start_link(
        host: ~c"149.154.167.50",
        port: 443,
        session_data: session_data,
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
        session_id: 123,
        now_ns_fun: fn -> 1_713_534_000_000_000_000 end,
        public_keys: MTProto.TelegramKeys.main_keys!(),
        pq_inner_data_mode: :dc,
        dc_id: 2,
        api_id: 12345,
        device_model: "exmt-dev",
        system_version: "OTP test",
        app_version: "0.1.0-test",
        system_lang_code: "en",
        lang_pack: "",
        lang_code: "en",
        update_state_store: {UpdateStateFileStore, update_state_path},
        timeout: 5_000,
        keepalive_interval: nil
      )

    assert_receive {:fake_socket, :connect, ~c"149.154.167.50", 443, socket,
                    _opts}

    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}

    %{connection: connection, socket: socket, session_data: session_data}
  end

  defp request_opts do
    [
      api_id: 12345,
      device_model: "exmt-dev",
      system_version: "OTP test",
      app_version: "0.1.0-test",
      system_lang_code: "en",
      lang_pack: "",
      lang_code: "en"
    ]
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

  defp decode_transport_frame(packet) do
    with {:ok, _decoder, [frame]} <-
           Abridged.feed(Abridged.new_decoder(), packet) do
      {:ok, frame}
    end
  end

  defp encode_constructor!(name, params) do
    definition = Registry.constructor!(:telegram_api, name)

    {:ok, encoded} =
      Encoder.encode_definition(definition, params, schema: :telegram_api)

    encoded
  end

  defp rpc_result_body(req_msg_id, result) do
    <<0xF35C6D01::little-unsigned-32, req_msg_id::little-signed-64,
      result::binary>>
  end

  defp send_encrypted_server_result(
         socket,
         session_data,
         body,
         message_id
       ) do
    send_encrypted_server_message(
      socket,
      session_data,
      body,
      message_id,
      1
    )
  end

  defp send_encrypted_server_message(
         socket,
         session_data,
         body,
         message_id,
         seq_no \\ 1
       ) do
    assert {:ok, server_payload} =
             EncryptedPacket.encode(
               %EncryptedPacket{
                 salt: session_data.server_salt,
                 session_id: 123,
                 message_id: message_id,
                 seq_no: seq_no,
                 body: body
               },
               SessionData.auth_key(session_data),
               sender: :server,
               padding_bytes: :binary.copy(<<0xBB>>, 64)
             )

    {:fake_socket, socket_pid, _test_pid} = socket
    send(socket_pid, {:deliver, Abridged.encode(server_payload)})
  end

  defp temp_update_state_path do
    System.tmp_dir!()
    |> Path.join(
      "exmt-update-state-" <>
        Integer.to_string(System.unique_integer([:positive, :monotonic])) <>
        ".term"
    )
  end
end
