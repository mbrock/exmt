defmodule MTProto.ConnectionTest do
  use ExUnit.Case, async: true

  alias MTProto.Auth.PublicKey
  alias MTProto.{Connection, PlainMessage}
  alias MTProto.Transport.Abridged

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

  test "connection drives the full auth handshake over framed TCP messages" do
    {:ok, key} = PublicKey.from_pem(MTProto.TelegramKeys.sample_pem())

    {:ok, connection} =
      Connection.start_link(
        host: ~c"149.154.167.40",
        port: 443,
        public_keys: [key],
        socket_mod: FakeSocket,
        socket_opts: [test_pid: self()],
        notify_to: self(),
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
             Connection.begin_auth_key_exchange(connection,
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
       encode_frame(MTProto.AuthExchangeSample.step1_response(), 1)}
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
       encode_frame(MTProto.AuthExchangeSample.step2_response(), 2)}
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
       encode_frame(MTProto.AuthExchangeSample.step3_response(), 3)}
    )

    assert_receive {:mtproto, ^connection, {:plain_message_received, 3, body}}
    assert body == MTProto.AuthExchangeSample.step3_response()

    assert_receive {:mtproto, ^connection, {:auth_key_created, result}}

    assert result.auth_key.data ==
             MTProto.AuthExchangeSample.expected_auth_key()

    assert result.server_salt ==
             MTProto.AuthExchangeSample.expected_server_salt()

    assert result.time_offset ==
             MTProto.AuthExchangeSample.expected_time_offset()

    assert_receive {:fake_socket, :setopts, ^socket, [active: :once]}
  end

  defp encode_frame(body, message_id) do
    %PlainMessage{message_id: message_id, body: body}
    |> PlainMessage.encode()
    |> Abridged.encode()
  end

  defp assert_plain_packet_body(packet, expected_body) do
    assert {:ok, _decoder, [frame]} =
             Abridged.feed(Abridged.new_decoder(), packet)

    assert {:ok, message} = PlainMessage.decode(frame)
    assert message.body == expected_body
  end
end
