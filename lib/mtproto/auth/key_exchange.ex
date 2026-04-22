defmodule MTProto.Auth.KeyExchange do
  @moduledoc """
  Pure MTProto auth-key exchange state machine.

  The exchange itself stays sans-IO and emits effects:

    * `{:send_tl, binary}` for the next unencrypted TL payload
    * `{:notify, term}` for decoded handshake milestones
  """

  alias MTProto.Auth.{
    ExchangeCrypto,
    ExchangeResult,
    Math,
    PublicKey,
    ResPQ,
    RSA,
    ServerDHInnerData
  }

  alias MTProto.{AuthKey, TL}

  @req_pq_multi 0xBE7E8EF1
  @res_pq 0x05162463
  @p_q_inner_data 0x83C95AEC
  @p_q_inner_data_dc 0xA9F55F95
  @req_dh_params 0xD712E4BE
  @server_dh_params_fail 0x79CB045D
  @server_dh_params_ok 0xD0E8075C
  @server_dh_inner_data 0xB5890DBA
  @client_dh_inner_data 0x6643B654
  @set_client_dh_params 0xF5045F1F
  @dh_gen_ok 0x3BCBF734
  @dh_gen_retry 0x46DC1FB9
  @dh_gen_fail 0xA69DAE02

  @type phase ::
          :idle
          | :awaiting_res_pq
          | :awaiting_server_dh_params
          | :awaiting_dh_gen
          | :complete

  @type effect :: {:send_tl, binary()} | {:notify, term()}

  @type t :: %__MODULE__{
          phase: phase(),
          nonce: binary() | nil,
          server_nonce: binary() | nil,
          new_nonce: binary() | nil,
          res_pq: ResPQ.t() | nil,
          p: binary() | nil,
          q: binary() | nil,
          public_key: PublicKey.t() | nil,
          temp_aes_key: binary() | nil,
          temp_aes_iv: binary() | nil,
          dh_inner_data: ServerDHInnerData.t() | nil,
          auth_key: AuthKey.t() | nil,
          server_salt: integer() | nil,
          time_offset: integer() | nil
        }

  defstruct phase: :idle,
            nonce: nil,
            server_nonce: nil,
            new_nonce: nil,
            res_pq: nil,
            p: nil,
            q: nil,
            public_key: nil,
            temp_aes_key: nil,
            temp_aes_iv: nil,
            dh_inner_data: nil,
            auth_key: nil,
            server_salt: nil,
            time_offset: nil

  @spec new(keyword()) :: t()
  def new(_opts \\ []), do: %__MODULE__{}

  @spec begin(t(), binary()) :: {:ok, t(), [effect()]} | {:error, term()}
  def begin(%__MODULE__{phase: :idle} = state, nonce)
      when is_binary(nonce) and byte_size(nonce) == 16 do
    {:ok, %{state | phase: :awaiting_res_pq, nonce: nonce},
     [
       {:send_tl, encode_req_pq_multi(nonce)},
       {:notify, {:request_sent, :req_pq_multi}}
     ]}
  end

  def begin(%__MODULE__{}, nonce)
      when not is_binary(nonce) or byte_size(nonce) != 16,
      do: {:error, :invalid_nonce}

  def begin(%__MODULE__{}, _nonce), do: {:error, :already_started}

  @spec receive_res_pq(t(), binary(), keyword()) ::
          {:ok, t(), [effect()]} | {:error, term()}
  def receive_res_pq(
        %__MODULE__{phase: :awaiting_res_pq, nonce: nonce} = state,
        body,
        opts
      )
      when is_binary(body) and is_list(opts) do
    with {:ok, %ResPQ{} = res_pq} <- decode_res_pq(body),
         :ok <- verify_nonce(nonce, res_pq.nonce),
         {:ok, public_keys} <- fetch_public_keys(opts),
         {:ok, public_key} <-
           PublicKey.select(
             public_keys,
             res_pq.server_public_key_fingerprints
           ),
         {:ok, {p, q}} <- Math.factor_pq(res_pq.pq),
         {:ok, random_bytes} <- fetch_binary_opt(opts, :random_bytes),
         :ok <-
           validate_pq_inner_data_mode(
             Keyword.get(opts, :pq_inner_data_mode, :bare)
           ) do
      p_bytes = Math.encode_unsigned(p)
      q_bytes = Math.encode_unsigned(q)

      with {:ok, new_nonce, encrypted_data} <-
             build_encrypted_pq_inner_data(
               res_pq,
               p_bytes,
               q_bytes,
               Keyword.get(opts, :pq_inner_data_mode, :bare),
               Keyword.get(opts, :dc_id, 0),
               public_key,
               random_bytes
             ) do
        request =
          encode_req_dh_params(
            nonce,
            res_pq.server_nonce,
            p_bytes,
            q_bytes,
            public_key.fingerprint,
            encrypted_data
          )

        {:ok,
         %{
           state
           | phase: :awaiting_server_dh_params,
             server_nonce: res_pq.server_nonce,
             new_nonce: new_nonce,
             res_pq: res_pq,
             p: p_bytes,
             q: q_bytes,
             public_key: public_key
         },
         [
           {:send_tl, request},
           {:notify, {:res_pq, res_pq}}
         ]}
      end
    end
  end

  def receive_res_pq(%__MODULE__{}, _body, _opts),
    do: {:error, :unexpected_phase}

  @spec receive_server_dh_params(t(), binary(), keyword()) ::
          {:ok, t(), [effect()]} | {:error, term()}
  def receive_server_dh_params(
        %__MODULE__{
          phase: :awaiting_server_dh_params,
          nonce: nonce,
          server_nonce: server_nonce,
          new_nonce: new_nonce
        } = state,
        body,
        opts
      )
      when is_binary(body) and is_list(opts) do
    with {:ok, now} <- fetch_integer_opt(opts, :now),
         {:ok, random_bytes} <- fetch_binary_opt(opts, :random_bytes),
         {:ok, response} <- decode_server_dh_params(body),
         :ok <- verify_nonce(nonce, response.nonce),
         :ok <- verify_server_nonce(server_nonce, response.server_nonce) do
      case response do
        %{type: :fail, new_nonce_hash: new_nonce_hash} ->
          with {:ok, expected_hash} <-
                 ExchangeCrypto.server_dh_fail_hash(new_nonce),
               :ok <-
                 verify_hash(
                   expected_hash,
                   new_nonce_hash,
                   :new_nonce_hash_mismatch
                 ) do
            {:error, :server_dh_params_fail}
          end

        %{type: :ok, encrypted_answer: encrypted_answer} ->
          with {:ok, {temp_aes_key, temp_aes_iv}} <-
                 ExchangeCrypto.temp_aes_key_iv(server_nonce, new_nonce),
               {:ok, decrypted_answer} <-
                 ExchangeCrypto.decrypt_data_with_hash(
                   encrypted_answer,
                   temp_aes_key,
                   temp_aes_iv
                 ),
               {:ok, %ServerDHInnerData{} = inner_data} <-
                 decode_server_dh_inner_data(decrypted_answer),
               :ok <- verify_nonce(nonce, inner_data.nonce),
               :ok <-
                 verify_server_nonce(server_nonce, inner_data.server_nonce),
               {:ok, next_state, request} <-
                 build_client_dh_request(
                   state,
                   inner_data,
                   temp_aes_key,
                   temp_aes_iv,
                   random_bytes,
                   now
                 ) do
            {:ok, next_state,
             [
               {:send_tl, request},
               {:notify, {:server_dh_inner_data, inner_data}}
             ]}
          end
      end
    end
  end

  def receive_server_dh_params(%__MODULE__{}, _body, _opts),
    do: {:error, :unexpected_phase}

  @spec receive_dh_gen(t(), binary()) ::
          {:ok, t(), [effect()]} | {:error, term()}
  def receive_dh_gen(
        %__MODULE__{
          phase: :awaiting_dh_gen,
          nonce: nonce,
          server_nonce: server_nonce,
          new_nonce: new_nonce,
          auth_key: %AuthKey{} = auth_key,
          server_salt: server_salt,
          time_offset: time_offset
        } = state,
        body
      )
      when is_binary(body) do
    with {:ok, response} <- decode_set_client_dh_params_answer(body),
         :ok <- verify_nonce(nonce, response.nonce),
         :ok <- verify_server_nonce(server_nonce, response.server_nonce),
         {:ok, expected_hash} <-
           AuthKey.calc_new_nonce_hash(
             auth_key,
             new_nonce,
             response.hash_number
           ),
         :ok <-
           verify_hash(
             expected_hash,
             response.new_nonce_hash,
             :new_nonce_hash_mismatch
           ) do
      case response.type do
        :ok ->
          result = %ExchangeResult{
            auth_key: auth_key,
            server_salt: server_salt,
            time_offset: time_offset
          }

          {:ok, %{state | phase: :complete},
           [
             {:notify, {:auth_key_created, result}}
           ]}

        :retry ->
          {:error, :dh_gen_retry}

        :fail ->
          {:error, :dh_gen_fail}
      end
    end
  end

  def receive_dh_gen(%__MODULE__{}, _body), do: {:error, :unexpected_phase}

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

  defp build_encrypted_pq_inner_data(
         %ResPQ{pq: pq, nonce: nonce, server_nonce: server_nonce},
         p_bytes,
         q_bytes,
         pq_inner_data_mode,
         dc_id,
         %PublicKey{} = public_key,
         random_bytes
       ) do
    if byte_size(random_bytes) < 32 do
      {:error, :insufficient_random_bytes}
    else
      <<new_nonce::binary-size(32), rsa_random::binary>> = random_bytes

      inner_data =
        case pq_inner_data_mode do
          :bare ->
            encode_p_q_inner_data(
              pq,
              p_bytes,
              q_bytes,
              nonce,
              server_nonce,
              new_nonce
            )

          :dc ->
            encode_p_q_inner_data_dc(
              pq,
              p_bytes,
              q_bytes,
              nonce,
              server_nonce,
              new_nonce,
              dc_id
            )
        end

      required =
        RSA.required_random_bytes(public_key.mode, byte_size(inner_data))

      if byte_size(rsa_random) < required do
        {:error, :insufficient_random_bytes}
      else
        with {:ok, encrypted_data} <-
               RSA.encrypt(
                 inner_data,
                 public_key,
                 binary_part(rsa_random, 0, required)
               ) do
          {:ok, new_nonce, encrypted_data}
        end
      end
    end
  end

  defp build_client_dh_request(
         state,
         %ServerDHInnerData{} = inner_data,
         temp_aes_key,
         temp_aes_iv,
         random_bytes,
         now
       ) do
    if byte_size(random_bytes) < 256 do
      {:error, :insufficient_random_bytes}
    else
      <<b_bytes::binary-size(256), padding_bytes::binary>> = random_bytes

      g = inner_data.g
      dh_prime = :binary.decode_unsigned(inner_data.dh_prime)
      g_a = :binary.decode_unsigned(inner_data.g_a)
      b = :binary.decode_unsigned(b_bytes)
      g_b = Math.mod_pow(g, b, dh_prime)
      auth_key_int = Math.mod_pow(g_a, b, dh_prime)

      with :ok <- Math.validate_dh(dh_prime, g, g_a, g_b),
           auth_key <- AuthKey.new!(Math.encode_unsigned(auth_key_int, 256)),
           {:ok, server_salt} <-
             ExchangeCrypto.server_salt(state.new_nonce, state.server_nonce),
           client_dh_inner_data <-
             encode_client_dh_inner_data(
               state.nonce,
               state.server_nonce,
               0,
               Math.encode_unsigned(g_b)
             ),
           {:ok, encrypted_data} <-
             ExchangeCrypto.encrypt_data_with_hash(
               client_dh_inner_data,
               temp_aes_key,
               temp_aes_iv,
               padding_bytes
             ) do
        next_state = %{
          state
          | phase: :awaiting_dh_gen,
            temp_aes_key: temp_aes_key,
            temp_aes_iv: temp_aes_iv,
            dh_inner_data: inner_data,
            auth_key: auth_key,
            server_salt: server_salt,
            time_offset: inner_data.server_time - now
        }

        {:ok, next_state,
         encode_set_client_dh_params(
           state.nonce,
           state.server_nonce,
           encrypted_data
         )}
      end
    end
  end

  defp encode_p_q_inner_data_dc(
         pq,
         p,
         q,
         nonce,
         server_nonce,
         new_nonce,
         dc_id
       ) do
    <<@p_q_inner_data_dc::little-unsigned-32, TL.encode_bytes(pq)::binary,
      TL.encode_bytes(p)::binary, TL.encode_bytes(q)::binary,
      TL.encode_int128(nonce)::binary, TL.encode_int128(server_nonce)::binary,
      TL.encode_int256(new_nonce)::binary, TL.encode_int(dc_id)::binary>>
  end

  defp encode_p_q_inner_data(pq, p, q, nonce, server_nonce, new_nonce) do
    <<@p_q_inner_data::little-unsigned-32, TL.encode_bytes(pq)::binary,
      TL.encode_bytes(p)::binary, TL.encode_bytes(q)::binary,
      TL.encode_int128(nonce)::binary, TL.encode_int128(server_nonce)::binary,
      TL.encode_int256(new_nonce)::binary>>
  end

  defp encode_req_dh_params(
         nonce,
         server_nonce,
         p,
         q,
         fingerprint,
         encrypted_data
       ) do
    <<@req_dh_params::little-unsigned-32, TL.encode_int128(nonce)::binary,
      TL.encode_int128(server_nonce)::binary, TL.encode_bytes(p)::binary,
      TL.encode_bytes(q)::binary, TL.encode_long(fingerprint)::binary,
      TL.encode_bytes(encrypted_data)::binary>>
  end

  defp decode_server_dh_params(
         <<@server_dh_params_ok::little-unsigned-32, rest::binary>>
       ) do
    with {:ok, nonce, rest} <- TL.decode_int128(rest),
         {:ok, server_nonce, rest} <- TL.decode_int128(rest),
         {:ok, encrypted_answer, <<>>} <- TL.decode_bytes(rest) do
      {:ok,
       %{
         type: :ok,
         nonce: nonce,
         server_nonce: server_nonce,
         encrypted_answer: encrypted_answer
       }}
    else
      {:ok, _value, _rest} -> {:error, :trailing_tl_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_server_dh_params(
         <<@server_dh_params_fail::little-unsigned-32, rest::binary>>
       ) do
    with {:ok, nonce, rest} <- TL.decode_int128(rest),
         {:ok, server_nonce, rest} <- TL.decode_int128(rest),
         {:ok, new_nonce_hash, <<>>} <- TL.decode_int128(rest) do
      {:ok,
       %{
         type: :fail,
         nonce: nonce,
         server_nonce: server_nonce,
         new_nonce_hash: new_nonce_hash
       }}
    else
      {:ok, _value, _rest} -> {:error, :trailing_tl_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_server_dh_params(
         <<constructor::little-unsigned-32, _::binary>>
       ),
       do: {:error, {:unexpected_constructor, constructor}}

  defp decode_server_dh_params(_), do: {:error, :short_server_dh_params}

  defp decode_server_dh_inner_data(
         <<@server_dh_inner_data::little-unsigned-32, rest::binary>>
       ) do
    with {:ok, nonce, rest} <- TL.decode_int128(rest),
         {:ok, server_nonce, rest} <- TL.decode_int128(rest),
         {:ok, g, rest} <- TL.decode_int(rest),
         {:ok, dh_prime, rest} <- TL.decode_bytes(rest),
         {:ok, g_a, rest} <- TL.decode_bytes(rest),
         {:ok, server_time, <<>>} <- TL.decode_int(rest) do
      {:ok,
       %ServerDHInnerData{
         nonce: nonce,
         server_nonce: server_nonce,
         g: g,
         dh_prime: dh_prime,
         g_a: g_a,
         server_time: server_time
       }}
    else
      {:ok, _value, _rest} -> {:error, :trailing_tl_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_server_dh_inner_data(
         <<constructor::little-unsigned-32, _::binary>>
       ),
       do: {:error, {:unexpected_constructor, constructor}}

  defp decode_server_dh_inner_data(_),
    do: {:error, :short_server_dh_inner_data}

  defp encode_client_dh_inner_data(nonce, server_nonce, retry_id, g_b) do
    <<@client_dh_inner_data::little-unsigned-32,
      TL.encode_int128(nonce)::binary, TL.encode_int128(server_nonce)::binary,
      TL.encode_long(retry_id)::binary, TL.encode_bytes(g_b)::binary>>
  end

  defp encode_set_client_dh_params(nonce, server_nonce, encrypted_data) do
    <<@set_client_dh_params::little-unsigned-32,
      TL.encode_int128(nonce)::binary, TL.encode_int128(server_nonce)::binary,
      TL.encode_bytes(encrypted_data)::binary>>
  end

  defp decode_set_client_dh_params_answer(
         <<@dh_gen_ok::little-unsigned-32, rest::binary>>
       ) do
    decode_dh_gen(rest, :ok, 1)
  end

  defp decode_set_client_dh_params_answer(
         <<@dh_gen_retry::little-unsigned-32, rest::binary>>
       ) do
    decode_dh_gen(rest, :retry, 2)
  end

  defp decode_set_client_dh_params_answer(
         <<@dh_gen_fail::little-unsigned-32, rest::binary>>
       ) do
    decode_dh_gen(rest, :fail, 3)
  end

  defp decode_set_client_dh_params_answer(
         <<constructor::little-unsigned-32, _::binary>>
       ),
       do: {:error, {:unexpected_constructor, constructor}}

  defp decode_set_client_dh_params_answer(_), do: {:error, :short_dh_gen}

  defp decode_dh_gen(rest, type, hash_number) do
    with {:ok, nonce, rest} <- TL.decode_int128(rest),
         {:ok, server_nonce, rest} <- TL.decode_int128(rest),
         {:ok, new_nonce_hash, <<>>} <- TL.decode_int128(rest) do
      {:ok,
       %{
         type: type,
         hash_number: hash_number,
         nonce: nonce,
         server_nonce: server_nonce,
         new_nonce_hash: new_nonce_hash
       }}
    else
      {:ok, _value, _rest} -> {:error, :trailing_tl_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_public_keys(opts) do
    case Keyword.fetch(opts, :public_keys) do
      {:ok, keys} when is_list(keys) -> {:ok, keys}
      {:ok, _keys} -> {:error, :invalid_public_keys}
      :error -> {:error, :missing_public_keys}
    end
  end

  defp fetch_binary_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_integer_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp validate_pq_inner_data_mode(mode) when mode in [:bare, :dc], do: :ok

  defp validate_pq_inner_data_mode(_mode),
    do: {:error, :invalid_pq_inner_data_mode}

  defp verify_nonce(expected, expected), do: :ok
  defp verify_nonce(_expected, _actual), do: {:error, :nonce_mismatch}

  defp verify_server_nonce(expected, expected), do: :ok

  defp verify_server_nonce(_expected, _actual),
    do: {:error, :server_nonce_mismatch}

  defp verify_hash(expected, expected, _reason), do: :ok
  defp verify_hash(_expected, _actual, reason), do: {:error, reason}
end
