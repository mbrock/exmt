defmodule MTProto.AuthExchangeTest do
  use ExUnit.Case, async: true

  alias MTProto.Auth.{
    ExchangeResult,
    KeyExchange,
    PublicKey,
    RSA,
    ServerDHInnerData
  }

  test "derives the Telegram sample public key fingerprint from PEM" do
    assert {:ok, key} = PublicKey.from_pem(MTProto.TelegramKeys.sample_pem())
    assert key.fingerprint == 0xB258_98DF_208D_2603
    assert key.mode == :padded
  end

  test "RSA padded exchange encryption matches the gotd zero-rand vector" do
    {:ok, key} = PublicKey.from_pem(MTProto.TelegramKeys.rsa_pad_test_pem())

    assert {:ok, encrypted} =
             RSA.encrypt(
               MTProto.AuthExchangeSample.rsa_pad_plaintext(),
               key,
               MTProto.AuthExchangeSample.rsa_pad_random_bytes()
             )

    assert encrypted ==
             MTProto.AuthExchangeSample.rsa_pad_expected_ciphertext()
  end

  test "pure auth-key exchange reproduces the official sample flow" do
    {:ok, key} = PublicKey.from_pem(MTProto.TelegramKeys.sample_pem())

    {:ok, state, effects} =
      KeyExchange.new()
      |> KeyExchange.begin(MTProto.AuthExchangeSample.step1_nonce())

    assert state.phase == :awaiting_res_pq

    assert effects == [
             {:send_tl, MTProto.AuthExchangeSample.step1_request()},
             {:notify, {:request_sent, :req_pq_multi}}
           ]

    {:ok, state, effects} =
      KeyExchange.receive_res_pq(
        state,
        MTProto.AuthExchangeSample.step1_response(),
        public_keys: [key],
        random_bytes: MTProto.AuthExchangeSample.step2_random(),
        dc_id: 0
      )

    assert state.phase == :awaiting_server_dh_params

    assert state.new_nonce ==
             binary_part(MTProto.AuthExchangeSample.step2_random(), 0, 32)

    assert [
             {:send_tl, step2_request},
             {:notify, {:res_pq, res_pq}}
           ] = effects

    assert step2_request == MTProto.AuthExchangeSample.step2_request()

    assert res_pq.server_public_key_fingerprints == [
             0xB258_98DF_208D_2603,
             0x9692_106D_A14B_9F02,
             0xC3B4_2B02_6CE8_6B21
           ]

    {:ok, state, effects} =
      KeyExchange.receive_server_dh_params(
        state,
        MTProto.AuthExchangeSample.step2_response(),
        random_bytes: MTProto.AuthExchangeSample.step3_random(),
        now: MTProto.AuthExchangeSample.step3_now()
      )

    assert state.phase == :awaiting_dh_gen

    assert state.server_salt ==
             MTProto.AuthExchangeSample.expected_server_salt()

    assert state.time_offset ==
             MTProto.AuthExchangeSample.expected_time_offset()

    assert [
             {:send_tl, step3_request},
             {:notify,
              {:server_dh_inner_data, %ServerDHInnerData{} = inner_data}}
           ] = effects

    assert step3_request == MTProto.AuthExchangeSample.step3_request()
    assert inner_data.g == 3
    assert inner_data.server_time == MTProto.AuthExchangeSample.step3_now()

    {:ok, state, effects} =
      KeyExchange.receive_dh_gen(
        state,
        MTProto.AuthExchangeSample.step3_response()
      )

    assert state.phase == :complete

    assert [
             {:notify, {:auth_key_created, %ExchangeResult{} = result}}
           ] = effects

    assert result.auth_key.data ==
             MTProto.AuthExchangeSample.expected_auth_key()

    assert result.server_salt ==
             MTProto.AuthExchangeSample.expected_server_salt()

    assert result.time_offset ==
             MTProto.AuthExchangeSample.expected_time_offset()
  end
end
