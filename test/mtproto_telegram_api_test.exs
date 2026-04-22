defmodule MTProto.Telegram.APITest do
  use ExUnit.Case, async: true

  alias MTProto.Telegram.API
  alias MTProto.Telegram.Request
  alias MTProto.Telegram.Schema
  alias MTProto.TL

  test "generated namespace modules return exact schema method tuples" do
    assert API.Help.getConfig() == {"help.getConfig", []}

    assert API.Messages.getHistory(peer: :self, limit: 10) ==
             {"messages.getHistory", [peer: :self, limit: 10]}
  end

  test "compiles help.getConfig from the schema" do
    assert {:ok,
            %Request{
              query: request,
              request: :help_get_config,
              result_type: "Config"
            }} = API.compile_request(API.Help.getConfig())

    assert request == <<0xC4F9186B::little-unsigned-32>>
  end

  test "wraps generated tuple requests in initConnection and invokeWithLayer" do
    assert {:ok, request} =
             API.wrap_request(API.Help.getConfig(),
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
             API.wrap_request(API.Help.getConfig())
  end

  test "defaults to the current layer" do
    assert {:ok, request} = API.invoke_with_layer(<<1, 2, 3, 4>>)

    assert request ==
             <<0xDA9B0D0D::little-unsigned-32,
               TL.encode_int(API.current_layer())::binary, 1, 2, 3, 4>>
  end

  test "compiles auth.sendCode with nested codeSettings from the schema" do
    assert {:ok,
            %Request{
              query: request,
              request: :auth_send_code,
              result_type: "auth.SentCode"
            }} =
             API.compile_request(
               API.Auth.sendCode(
                 phone_number: "+15551234567",
                 api_hash: "hash-123",
                 settings: [allow_app_hash: true]
               ),
               api_id: 12345
             )

    assert request ==
             <<0xA677244F::little-unsigned-32,
               TL.encode_bytes("+15551234567")::binary,
               TL.encode_int(12345)::binary,
               TL.encode_bytes("hash-123")::binary,
               0xAD253D78::little-unsigned-32, TL.encode_int(0x10)::binary>>
  end

  test "compiles auth.signIn with phone code" do
    assert {:ok,
            %Request{
              query: request,
              request: :auth_sign_in,
              result_type: "auth.Authorization"
            }} =
             API.compile_request(
               API.Auth.signIn(
                 phone_number: "+15551234567",
                 phone_code_hash: "code-hash",
                 phone_code: "12345"
               )
             )

    assert request ==
             <<0x8D52A951::little-unsigned-32, TL.encode_int(1)::binary,
               TL.encode_bytes("+15551234567")::binary,
               TL.encode_bytes("code-hash")::binary,
               TL.encode_bytes("12345")::binary>>
  end

  test "compiles users.getFullUser for the current user" do
    assert {:ok,
            %Request{
              query: request,
              request: :users_get_full_user,
              result_type: "users.UserFull"
            }} =
             API.compile_request(API.Users.getFullUser(id: :self))

    assert request ==
             <<0xB60F5918::little-unsigned-32,
               0xF7C1B13F::little-unsigned-32>>
  end

  test "compiles updates.getState" do
    assert {:ok,
            %Request{
              query: request,
              request: :updates_get_state,
              result_type: "updates.State"
            }} = API.compile_request(API.Updates.getState())

    assert request == <<0xEDD4882A::little-unsigned-32>>
  end

  test "compiles help.getNearestDc" do
    assert {:ok,
            %Request{
              query: request,
              request: :help_get_nearest_dc,
              result_type: "NearestDc"
            }} = API.compile_request(API.Help.getNearestDc())

    assert request == <<0x1FB33026::little-unsigned-32>>
  end

  test "compiles contacts.getContacts" do
    assert {:ok,
            %Request{
              query: request,
              request: :contacts_get_contacts,
              result_type: "contacts.Contacts"
            }} =
             API.compile_request(API.Contacts.getContacts(hash: 42))

    assert request ==
             <<0x5DD69E12::little-unsigned-32,
               TL.encode_signed_long(42)::binary>>
  end

  test "compiles messages.getDialogs" do
    assert {:ok,
            %Request{
              query: request,
              request: :messages_get_dialogs,
              result_type: "messages.Dialogs"
            }} =
             API.compile_request(
               API.Messages.getDialogs(
                 offset_date: 0,
                 offset_id: 0,
                 offset_peer: :empty,
                 limit: 25,
                 hash: 0
               )
             )

    assert request ==
             <<0xA0F4CB4F::little-unsigned-32, TL.encode_int(0)::binary,
               TL.encode_int(0)::binary, TL.encode_int(0)::binary,
               0x7F3B18EA::little-unsigned-32, TL.encode_int(25)::binary,
               TL.encode_signed_long(0)::binary>>
  end

  test "compiles messages.getHistory" do
    assert {:ok,
            %Request{
              query: request,
              request: :messages_get_history,
              result_type: "messages.Messages"
            }} =
             API.compile_request(
               API.Messages.getHistory(
                 peer: :self,
                 offset_id: 0,
                 offset_date: 0,
                 add_offset: 0,
                 limit: 10,
                 max_id: 0,
                 min_id: 0,
                 hash: 0
               )
             )

    assert request ==
             <<0x4423E6C5::little-unsigned-32, 0x7DA07EC9::little-unsigned-32,
               TL.encode_int(0)::binary, TL.encode_int(0)::binary,
               TL.encode_int(0)::binary, TL.encode_int(10)::binary,
               TL.encode_int(0)::binary, TL.encode_int(0)::binary,
               TL.encode_signed_long(0)::binary>>
  end

  test "compiles messages.sendMessage" do
    assert {:ok,
            %Request{
              query: request,
              request: :messages_send_message,
              result_type: "Updates"
            }} =
             API.compile_request(
               API.Messages.sendMessage(
                 peer: :self,
                 message: "hello",
                 random_id: 123_456
               )
             )

    assert request ==
             <<Schema.function!("messages.sendMessage").id::little-unsigned-32,
               TL.encode_int(0)::binary, 0x7DA07EC9::little-unsigned-32,
               TL.encode_bytes("hello")::binary,
               TL.encode_signed_long(123_456)::binary>>
  end

  test "compiles updates.getDifference from update state fields" do
    assert {:ok,
            %Request{
              query: request,
              request: :updates_get_difference,
              result_type: "updates.Difference"
            }} =
             API.compile_request(
               API.Updates.getDifference(
                 pts: 11,
                 date: 33,
                 qts: 22
               )
             )

    assert request ==
             <<0x19C2F763::little-unsigned-32, TL.encode_int(0)::binary,
               TL.encode_int(11)::binary, TL.encode_int(33)::binary,
               TL.encode_int(22)::binary>>
  end
end
