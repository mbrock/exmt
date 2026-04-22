defmodule MTProto.APITest do
  use ExUnit.Case, async: true

  alias MTProto.API
  alias MTProto.TL

  test "wraps help.getConfig in initConnection and invokeWithLayer" do
    assert {:ok, request} =
             API.wrap_request(API.help_get_config(),
               api_id: 12345,
               device_model: "exmt-dev",
               system_version: "OTP test",
               app_version: "0.1.0-test",
               system_lang_code: "en",
               lang_pack: "",
               lang_code: "en",
               layer: 214
             )

    expected =
      <<0xDA9B0D0D::little-unsigned-32, TL.encode_int(214)::binary,
        0xC1CD5EA9::little-unsigned-32, TL.encode_int(0)::binary,
        TL.encode_int(12345)::binary, TL.encode_bytes("exmt-dev")::binary,
        TL.encode_bytes("OTP test")::binary,
        TL.encode_bytes("0.1.0-test")::binary, TL.encode_bytes("en")::binary,
        TL.encode_bytes("")::binary, TL.encode_bytes("en")::binary,
        0xC4F9186B::little-unsigned-32>>

    assert request == expected
  end

  test "requires api_id to build initConnection" do
    assert {:error, {:missing_option, :api_id}} =
             API.wrap_request(API.help_get_config())
  end

  test "defaults to the current layer" do
    assert {:ok, request} =
             API.invoke_with_layer(<<1, 2, 3, 4>>)

    assert request ==
             <<0xDA9B0D0D::little-unsigned-32,
               TL.encode_int(API.current_layer())::binary, 1, 2, 3, 4>>
  end

  test "encodes codeSettings with optional flags" do
    assert {:ok, encoded} =
             API.code_settings(
               allow_flashcall: true,
               allow_app_hash: true,
               logout_tokens: ["logout-1", "logout-2"],
               token: "firebase-token",
               app_sandbox: false
             )

    expected_flags = 0x1 + 0x10 + 0x40 + 0x100

    assert encoded ==
             <<0xAD253D78::little-unsigned-32,
               TL.encode_int(expected_flags)::binary,
               TL.encode_vector(
                 ["logout-1", "logout-2"],
                 &TL.encode_bytes/1
               )::binary, TL.encode_bytes("firebase-token")::binary,
               TL.encode_bool(false)::binary>>
  end

  test "builds auth.sendCode with nested codeSettings" do
    assert {:ok, request} =
             API.auth_send_code("+15551234567", "hash-123",
               api_id: 12345,
               settings: [allow_app_hash: true]
             )

    assert request ==
             <<0xA677244F::little-unsigned-32,
               TL.encode_bytes("+15551234567")::binary,
               TL.encode_int(12345)::binary,
               TL.encode_bytes("hash-123")::binary,
               0xAD253D78::little-unsigned-32, TL.encode_int(0x10)::binary>>
  end

  test "builds auth.signIn with phone code" do
    assert {:ok, request} =
             API.auth_sign_in("+15551234567", "code-hash", "12345")

    assert request ==
             <<0x8D52A951::little-unsigned-32, TL.encode_int(1)::binary,
               TL.encode_bytes("+15551234567")::binary,
               TL.encode_bytes("code-hash")::binary,
               TL.encode_bytes("12345")::binary>>
  end
end
