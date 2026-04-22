defmodule MTProto.Telegram.APITest do
  use ExUnit.Case, async: true

  alias MTProto.Telegram.API
  alias MTProto.Telegram.Request
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
    assert {:ok, request} = API.invoke_with_layer(<<1, 2, 3, 4>>)

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
    assert {:ok,
            %Request{
              query: request,
              request: :auth_send_code,
              result_type: "auth.SentCode"
            }} =
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
    assert {:ok,
            %Request{
              query: request,
              request: :auth_sign_in,
              result_type: "auth.Authorization"
            }} =
             API.auth_sign_in("+15551234567", "code-hash", "12345")

    assert request ==
             <<0x8D52A951::little-unsigned-32, TL.encode_int(1)::binary,
               TL.encode_bytes("+15551234567")::binary,
               TL.encode_bytes("code-hash")::binary,
               TL.encode_bytes("12345")::binary>>
  end

  test "builds users.getFullUser for the current user" do
    assert %Request{
             query: request,
             request: :users_get_self,
             result_type: "users.UserFull"
           } = API.users_get_self()

    assert request ==
             <<0xB60F5918::little-unsigned-32,
               0xF7C1B13F::little-unsigned-32>>
  end

  test "builds updates.getState" do
    assert %Request{
             query: request,
             request: :updates_get_state,
             result_type: "updates.State"
           } = API.updates_get_state()

    assert request == <<0xEDD4882A::little-unsigned-32>>
  end

  test "builds help.getNearestDc" do
    assert %Request{
             query: request,
             request: :help_get_nearest_dc,
             result_type: "NearestDc"
           } = API.help_get_nearest_dc()

    assert request == <<0x1FB33026::little-unsigned-32>>
  end

  test "builds contacts.getContacts" do
    assert {:ok,
            %Request{
              query: request,
              request: :contacts_get_contacts,
              result_type: "contacts.Contacts"
            }} = API.contacts_get_contacts(hash: 42)

    assert request ==
             <<0x5DD69E12::little-unsigned-32, TL.encode_long(42)::binary>>
  end

  test "builds messages.getDialogs using inputPeerEmpty by default" do
    assert {:ok,
            %Request{
              query: request,
              request: :messages_get_dialogs,
              result_type: "messages.Dialogs"
            }} = API.messages_get_dialogs(limit: 25)

    assert request ==
             <<0xA0F4CB4F::little-unsigned-32, TL.encode_int(0)::binary,
               TL.encode_int(0)::binary, TL.encode_int(0)::binary,
               0x7F3B18EA::little-unsigned-32, TL.encode_int(25)::binary,
               TL.encode_long(0)::binary>>
  end

  test "builds messages.getHistory for inputPeerSelf by default" do
    assert {:ok,
            %Request{
              query: request,
              request: :messages_get_history,
              result_type: "messages.Messages"
            }} = API.messages_get_history(limit: 10)

    assert request ==
             <<0x4423E6C5::little-unsigned-32, 0x7DA07EC9::little-unsigned-32,
               TL.encode_int(0)::binary, TL.encode_int(0)::binary,
               TL.encode_int(0)::binary, TL.encode_int(10)::binary,
               TL.encode_int(0)::binary, TL.encode_int(0)::binary,
               TL.encode_long(0)::binary>>
  end

  test "builds messages.sendMessage for a self peer" do
    assert {:ok,
            %Request{
              query: request,
              request: :messages_send_message,
              result_type: "Updates"
            }} =
             API.messages_send_message("hello",
               peer: :self,
               random_id: 123_456
             )

    assert request ==
             <<0x545CD15A::little-unsigned-32, TL.encode_int(0)::binary,
               0x7DA07EC9::little-unsigned-32,
               TL.encode_bytes("hello")::binary,
               TL.encode_signed_long(123_456)::binary>>
  end

  test "builds updates.getDifference from update state" do
    state =
      MTProto.Telegram.UpdateState.new!(
        pts: 11,
        qts: 22,
        date: 33,
        seq: 44
      )

    assert {:ok,
            %Request{
              query: request,
              request: :updates_get_difference,
              result_type: "updates.Difference"
            }} = API.updates_get_difference(state)

    assert request ==
             <<0x19C2F763::little-unsigned-32, TL.encode_int(0)::binary,
               TL.encode_int(11)::binary, TL.encode_int(33)::binary,
               TL.encode_int(22)::binary>>
  end
end
