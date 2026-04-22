defmodule MTProto.TL.EncoderTest do
  use ExUnit.Case, async: true

  alias MTProto.TL
  alias MTProto.TL.Encoder

  test "encodes telegram definitions with a supplied schema module" do
    definition =
      MTProto.TL.Schema.Registry.function!(:telegram_api, "auth.sendCode")

    assert {:ok, request} =
             Encoder.encode_definition(
               definition,
               [
                 phone_number: "+15551234567",
                 api_id: 12345,
                 api_hash: "hash-123",
                 settings: [allow_app_hash: true]
               ],
               schema: :telegram_api
             )

    assert request ==
             <<0xA677244F::little-unsigned-32,
               TL.encode_bytes("+15551234567")::binary,
               TL.encode_int(12345)::binary,
               TL.encode_bytes("hash-123")::binary,
               0xAD253D78::little-unsigned-32, TL.encode_int(0x10)::binary>>
  end

  test "accepts caller-defined value normalization hooks" do
    definition =
      MTProto.TL.Schema.Registry.function!(:telegram_api, "users.getFullUser")

    assert {:ok, request} =
             Encoder.encode_definition(
               definition,
               [id: :self],
               schema: :telegram_api,
               normalize_value: &normalize_value/2
             )

    assert request ==
             <<0xB60F5918::little-unsigned-32,
               0xF7C1B13F::little-unsigned-32>>
  end

  defp normalize_value("InputUser", :self), do: {"inputUserSelf", []}
  defp normalize_value(_type_name, value), do: value
end
