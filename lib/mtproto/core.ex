defmodule MTProto.Core do
  @moduledoc """
  Pure state machine for the first MTProto client steps.

  The core never performs IO itself. Instead it emits effects:

    * `{:send_bytes, binary}` for the transport adapter to write
    * `{:notify, term}` for higher-level state updates
  """

  alias MTProto.Auth.KeyExchange
  alias MTProto.MessageId
  alias MTProto.PlainMessage
  alias MTProto.Transport.Abridged

  @type phase :: :idle | :awaiting_res_pq | :awaiting_dh_params
  @type effect :: {:send_bytes, binary()} | {:notify, term()}

  @type t :: %__MODULE__{
          phase: phase(),
          transport: module(),
          transport_started?: boolean(),
          transport_decoder: term(),
          last_msg_id: non_neg_integer() | nil,
          pending_nonce: binary() | nil,
          server_nonce: binary() | nil,
          res_pq: MTProto.Auth.ResPQ.t() | nil
        }

  defstruct phase: :idle,
            transport: Abridged,
            transport_started?: false,
            transport_decoder: nil,
            last_msg_id: nil,
            pending_nonce: nil,
            server_nonce: nil,
            res_pq: nil

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    transport = Keyword.get(opts, :transport, Abridged)

    %__MODULE__{
      transport: transport,
      transport_decoder: transport.new_decoder()
    }
  end

  @spec begin_auth_key_exchange(t(), non_neg_integer(), binary()) ::
          {:ok, t(), [effect()]} | {:error, term()}
  def begin_auth_key_exchange(
        %__MODULE__{phase: :idle} = state,
        now_ns,
        nonce
      )
      when is_integer(now_ns) and now_ns >= 0 and is_binary(nonce) and
             byte_size(nonce) == 16 do
    msg_id = MessageId.next(state.last_msg_id, now_ns)
    body = KeyExchange.encode_req_pq_multi(nonce)

    packet =
      %PlainMessage{message_id: msg_id, body: body}
      |> PlainMessage.encode()
      |> state.transport.encode()

    effects =
      maybe_transport_prefix(state) ++
        [
          {:send_bytes, packet},
          {:notify, {:request_sent, :req_pq_multi, msg_id}}
        ]

    {:ok,
     %{
       state
       | phase: :awaiting_res_pq,
         transport_started?: true,
         last_msg_id: msg_id,
         pending_nonce: nonce
     }, effects}
  end

  def begin_auth_key_exchange(%__MODULE__{}, _now_ns, nonce)
      when not is_binary(nonce) do
    {:error, :invalid_nonce}
  end

  def begin_auth_key_exchange(%__MODULE__{}, _now_ns, nonce)
      when byte_size(nonce) != 16 do
    {:error, :invalid_nonce}
  end

  def begin_auth_key_exchange(%__MODULE__{}, _now_ns, _nonce) do
    {:error, :already_started}
  end

  @spec receive_bytes(t(), binary()) ::
          {:ok, t(), [effect()]} | {:error, term(), t()}
  def receive_bytes(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    {:ok, decoder, frames} =
      state.transport.feed(state.transport_decoder, chunk)

    frames
    |> Enum.reduce_while(
      {:ok, %{state | transport_decoder: decoder}, []},
      fn frame, {:ok, acc_state, effects} ->
        case handle_frame(acc_state, frame) do
          {:ok, next_state, next_effects} ->
            {:cont, {:ok, next_state, effects ++ next_effects}}

          {:error, reason} ->
            {:halt, {:error, reason, acc_state}}
        end
      end
    )
  end

  defp maybe_transport_prefix(%__MODULE__{transport_started?: true}), do: []

  defp maybe_transport_prefix(%__MODULE__{transport: transport}),
    do: [{:send_bytes, transport.client_prefix()}]

  defp handle_frame(state, {:quick_ack, token}) do
    {:ok, state, [{:notify, {:quick_ack, token}}]}
  end

  defp handle_frame(
         %__MODULE__{phase: :awaiting_res_pq, pending_nonce: nonce} = state,
         frame
       )
       when is_binary(frame) do
    with {:ok, plain_message} <- PlainMessage.decode(frame),
         {:ok, res_pq} <- KeyExchange.decode_res_pq(plain_message.body),
         :ok <- verify_nonce(nonce, res_pq.nonce) do
      {:ok,
       %{
         state
         | phase: :awaiting_dh_params,
           server_nonce: res_pq.server_nonce,
           res_pq: res_pq
       }, [{:notify, {:res_pq, plain_message.message_id, res_pq}}]}
    end
  end

  defp handle_frame(%__MODULE__{phase: phase} = state, frame)
       when is_binary(frame) do
    with {:ok, plain_message} <- PlainMessage.decode(frame) do
      {:ok, state, [{:notify, {:plain_message, phase, plain_message}}]}
    end
  end

  defp verify_nonce(nonce, nonce), do: :ok
  defp verify_nonce(_expected, _actual), do: {:error, :nonce_mismatch}
end
