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
end
