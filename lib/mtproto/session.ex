defmodule MTProto.Session do
  @moduledoc """
  Pure post-auth MTProto session state machine.

  This module owns the session-level policy that sits between transport framing
  and higher-level TL/RPC handling:

    * encrypted packet encode/decode
    * time-adjusted client `msg_id` generation
    * outbound `seq_no` policy
    * server salt tracking
    * a minimal set of service-message handlers

  Like the auth exchange, it stays sans-IO and emits effects:

    * `{:send_encrypted, binary}` for transport adapters to write
    * `{:notify, term}` for decoded session milestones
  """

  alias MTProto.Auth.ExchangeResult
  alias MTProto.{AuthKey, EncryptedPacket, MessageId, TL}

  @ping 0x7ABE77EC
  @pong 0x347773C5
  @msgs_ack 0x62D6B459
  @new_session_created 0x9EC20908
  @bad_server_salt 0xEDAB447B
  @rpc_result 0xF35C6D01
  @msg_container 0x73F1F8DC

  @nanoseconds_per_second 1_000_000_000

  @type effect :: {:send_encrypted, binary()} | {:notify, term()}

  @type t :: %__MODULE__{
          auth_key: AuthKey.t(),
          server_salt: integer(),
          session_id: integer(),
          time_offset: integer(),
          last_msg_id: non_neg_integer() | nil,
          sent_content_messages: non_neg_integer()
        }

  defstruct [
    :auth_key,
    :server_salt,
    :session_id,
    :time_offset,
    :last_msg_id,
    sent_content_messages: 0
  ]

  @spec new(ExchangeResult.t()) :: {:ok, t()} | {:error, term()}
  def new(%ExchangeResult{} = result) do
    new(result, [])
  end

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, auth_key} <- fetch_auth_key(opts),
         {:ok, server_salt} <- fetch_integer_opt(opts, :server_salt),
         {:ok, session_id} <- fetch_integer_opt(opts, :session_id),
         {:ok, time_offset} <- fetch_integer_opt(opts, :time_offset, 0),
         :ok <- validate_signed_64(server_salt, :invalid_server_salt),
         :ok <- validate_signed_64(session_id, :invalid_session_id),
         :ok <- validate_last_msg_id(Keyword.get(opts, :last_msg_id)),
         :ok <-
           validate_sent_content_messages(
             Keyword.get(opts, :sent_content_messages, 0)
           ) do
      {:ok,
       %__MODULE__{
         auth_key: auth_key,
         server_salt: server_salt,
         session_id: session_id,
         time_offset: time_offset,
         last_msg_id: Keyword.get(opts, :last_msg_id),
         sent_content_messages: Keyword.get(opts, :sent_content_messages, 0)
       }}
    end
  end

  @spec new(ExchangeResult.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%ExchangeResult{} = result, opts) when is_list(opts) do
    new(
      Keyword.merge(
        [
          auth_key: result.auth_key,
          server_salt: result.server_salt,
          time_offset: result.time_offset
        ],
        opts
      )
    )
  end

  @spec send_ping(t(), non_neg_integer(), integer(), keyword()) ::
          {:ok, t(), [effect()]} | {:error, term()}
  def send_ping(session, now_ns, ping_id, opts \\ [])

  def send_ping(%__MODULE__{} = session, now_ns, ping_id, opts)
      when is_integer(now_ns) and now_ns >= 0 and is_integer(ping_id) do
    with {:ok, next_session, packet, encrypted} <-
           send_message(session, now_ns, encode_ping(ping_id), false, opts) do
      {:ok, next_session,
       [
         {:send_encrypted, encrypted},
         {:notify, {:encrypted_packet_sent, packet}},
         {:notify,
          {:session_message_sent, packet.message_id, packet.seq_no,
           packet.body}},
         {:notify, {:ping_sent, packet.message_id, ping_id}}
       ]}
    end
  end

  def send_ping(%__MODULE__{}, _now_ns, _ping_id, _opts),
    do: {:error, :invalid_now}

  @spec receive_packet(t(), binary(), non_neg_integer(), keyword()) ::
          {:ok, t(), [effect()]} | {:error, term()}
  def receive_packet(session, payload, now_ns, opts \\ [])

  def receive_packet(%__MODULE__{} = session, payload, now_ns, opts)
      when is_binary(payload) and is_integer(now_ns) and now_ns >= 0 do
    with {:ok, packet} <-
           EncryptedPacket.decode(payload, session.auth_key,
             sender: :server,
             session_id: session.session_id
           ),
         {:ok, next_session, effects} <- handle_packet(session, packet),
         {:ok, final_session, ack_effects} <-
           maybe_ack(next_session, packet, now_ns, opts) do
      {:ok, final_session, effects ++ ack_effects}
    end
  end

  def receive_packet(%__MODULE__{}, _payload, _now_ns, _opts),
    do: {:error, :invalid_now}

  defp handle_packet(%__MODULE__{} = session, %EncryptedPacket{} = packet) do
    with {:ok, next_session, effects} <-
           handle_message(
             session,
             packet.message_id,
             packet.seq_no,
             packet.body,
             [
               {:notify, {:encrypted_packet_received, packet}},
               {:notify,
                {:session_message_received, packet.message_id, packet.seq_no,
                 packet.body}}
             ]
           ) do
      {:ok, next_session, effects}
    end
  end

  defp handle_message(
         session,
         _message_id,
         _seq_no,
         <<@pong::little-unsigned-32, rest::binary>>,
         effects
       ) do
    with {:ok, msg_id, rest} <- TL.decode_signed_long(rest),
         {:ok, ping_id, <<>>} <- TL.decode_signed_long(rest) do
      {:ok, session, effects ++ [{:notify, {:pong, msg_id, ping_id}}]}
    end
  end

  defp handle_message(
         session,
         _message_id,
         _seq_no,
         <<@msgs_ack::little-unsigned-32, rest::binary>>,
         effects
       ) do
    with {:ok, msg_ids, <<>>} <-
           TL.decode_vector(rest, &TL.decode_signed_long/1) do
      {:ok, session, effects ++ [{:notify, {:msgs_ack, msg_ids}}]}
    end
  end

  defp handle_message(
         session,
         _message_id,
         _seq_no,
         <<@new_session_created::little-unsigned-32, rest::binary>>,
         effects
       ) do
    with {:ok, first_msg_id, rest} <- TL.decode_signed_long(rest),
         {:ok, unique_id, rest} <- TL.decode_signed_long(rest),
         {:ok, server_salt, <<>>} <- TL.decode_signed_long(rest) do
      {:ok, %{session | server_salt: server_salt},
       effects ++
         [
           {:notify,
            {:new_session_created, first_msg_id, unique_id, server_salt}}
         ]}
    end
  end

  defp handle_message(
         session,
         _message_id,
         _seq_no,
         <<@bad_server_salt::little-unsigned-32, rest::binary>>,
         effects
       ) do
    with {:ok, bad_msg_id, rest} <- TL.decode_signed_long(rest),
         {:ok, bad_msg_seq_no, rest} <- TL.decode_int(rest),
         {:ok, error_code, rest} <- TL.decode_int(rest),
         {:ok, new_server_salt, <<>>} <- TL.decode_signed_long(rest) do
      {:ok, %{session | server_salt: new_server_salt},
       effects ++
         [
           {:notify,
            {:bad_server_salt, bad_msg_id, bad_msg_seq_no, error_code,
             new_server_salt}}
         ]}
    end
  end

  defp handle_message(
         session,
         _message_id,
         _seq_no,
         <<@rpc_result::little-unsigned-32, rest::binary>>,
         effects
       ) do
    with {:ok, req_msg_id, result} <- decode_rpc_result(rest) do
      {:ok, session,
       effects ++ [{:notify, {:rpc_result, req_msg_id, result}}]}
    end
  end

  defp handle_message(
         session,
         _message_id,
         _seq_no,
         <<@msg_container::little-unsigned-32, count::little-signed-32,
           rest::binary>>,
         effects
       )
       when count >= 0 do
    with {:ok, messages, <<>>} <- decode_container_messages(count, rest, []) do
      Enum.reduce_while(messages, {:ok, session, effects}, fn message,
                                                              {:ok,
                                                               acc_session,
                                                               acc_effects} ->
        case handle_message(
               acc_session,
               message.message_id,
               message.seq_no,
               message.body,
               acc_effects ++
                 [
                   {:notify,
                    {:session_message_received, message.message_id,
                     message.seq_no, message.body}}
                 ]
             ) do
          {:ok, next_session, next_effects} ->
            {:cont, {:ok, next_session, next_effects}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp handle_message(session, message_id, seq_no, body, effects)
       when is_binary(body) do
    {:ok, session,
     effects ++
       [
         {:notify, {:unhandled_session_message, message_id, seq_no, body}}
       ]}
  end

  defp maybe_ack(session, %EncryptedPacket{seq_no: seq_no}, _now_ns, _opts)
       when rem(seq_no, 2) == 0 do
    {:ok, session, []}
  end

  defp maybe_ack(
         %__MODULE__{} = session,
         %EncryptedPacket{message_id: message_id},
         now_ns,
         opts
       ) do
    send_ack(session, now_ns, [message_id], opts)
  end

  defp send_ack(%__MODULE__{} = session, now_ns, msg_ids, opts) do
    with {:ok, next_session, packet, encrypted} <-
           send_message(
             session,
             now_ns,
             encode_msgs_ack(msg_ids),
             false,
             opts
           ) do
      {:ok, next_session,
       [
         {:send_encrypted, encrypted},
         {:notify, {:encrypted_packet_sent, packet}},
         {:notify,
          {:session_message_sent, packet.message_id, packet.seq_no,
           packet.body}},
         {:notify, {:msgs_ack_sent, packet.message_id, msg_ids}}
       ]}
    end
  end

  defp send_message(%__MODULE__{} = session, now_ns, body, content?, opts) do
    packet = %EncryptedPacket{
      salt: session.server_salt,
      session_id: session.session_id,
      message_id: next_msg_id(session, now_ns),
      seq_no: next_seq_no(session, content?),
      body: body
    }

    with {:ok, encrypted} <-
           EncryptedPacket.encode(packet, session.auth_key,
             sender: :client,
             padding_bytes: Keyword.get(opts, :padding_bytes, <<>>)
           ),
         {:ok, finalized_packet} <-
           EncryptedPacket.decode(encrypted, session.auth_key,
             sender: :client,
             session_id: session.session_id
           ) do
      {:ok, advance_outbound(session, finalized_packet.message_id, content?),
       finalized_packet, encrypted}
    end
  end

  defp next_msg_id(%__MODULE__{} = session, now_ns) do
    adjusted_now_ns =
      max(now_ns + session.time_offset * @nanoseconds_per_second, 0)

    MessageId.next(session.last_msg_id, adjusted_now_ns)
  end

  defp next_seq_no(%__MODULE__{sent_content_messages: sent}, false),
    do: sent * 2

  defp next_seq_no(%__MODULE__{sent_content_messages: sent}, true),
    do: sent * 2 + 1

  defp advance_outbound(%__MODULE__{} = session, message_id, false) do
    %{session | last_msg_id: message_id}
  end

  defp advance_outbound(%__MODULE__{} = session, message_id, true) do
    %{
      session
      | last_msg_id: message_id,
        sent_content_messages: session.sent_content_messages + 1
    }
  end

  defp encode_ping(ping_id) do
    <<@ping::little-unsigned-32, ping_id::little-signed-64>>
  end

  defp encode_msgs_ack(msg_ids) when is_list(msg_ids) do
    <<@msgs_ack::little-unsigned-32,
      TL.encode_vector(msg_ids, &TL.encode_signed_long/1)::binary>>
  end

  defp decode_rpc_result(rest) do
    with {:ok, req_msg_id, result} <- TL.decode_signed_long(rest) do
      {:ok, req_msg_id, result}
    end
  end

  defp decode_container_messages(0, rest, messages),
    do: {:ok, Enum.reverse(messages), rest}

  defp decode_container_messages(count, rest, messages) when count > 0 do
    with {:ok, message_id, rest} <- TL.decode_signed_long(rest),
         {:ok, seq_no, rest} <- TL.decode_int(rest),
         {:ok, body_len, rest} <- TL.decode_int(rest),
         true <- body_len >= 0 and body_len <= byte_size(rest),
         <<body::binary-size(body_len), tail::binary>> <- rest do
      decode_container_messages(
        count - 1,
        tail,
        [
          %{
            message_id: message_id,
            seq_no: seq_no,
            body: body
          }
          | messages
        ]
      )
    else
      false -> {:error, :invalid_container_message}
      _ -> {:error, :invalid_container_message}
    end
  end

  defp fetch_auth_key(opts) do
    case Keyword.fetch(opts, :auth_key) do
      {:ok, %AuthKey{} = auth_key} -> {:ok, auth_key}
      {:ok, _auth_key} -> {:error, :invalid_auth_key}
      :error -> {:error, :missing_auth_key}
    end
  end

  defp fetch_integer_opt(opts, key, default \\ :no_default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error when default != :no_default -> {:ok, default}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp validate_last_msg_id(nil), do: :ok

  defp validate_last_msg_id(last_msg_id)
       when is_integer(last_msg_id) and last_msg_id >= 0,
       do: :ok

  defp validate_last_msg_id(_last_msg_id), do: {:error, :invalid_last_msg_id}

  defp validate_sent_content_messages(sent_content_messages)
       when is_integer(sent_content_messages) and sent_content_messages >= 0,
       do: :ok

  defp validate_sent_content_messages(_sent_content_messages),
    do: {:error, :invalid_sent_content_messages}

  defp validate_signed_64(value, _error)
       when is_integer(value) and value >= -0x8000_0000_0000_0000 and
              value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: :ok

  defp validate_signed_64(_value, error), do: {:error, error}
end
