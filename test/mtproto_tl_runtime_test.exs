defmodule MTProto.TL.RuntimeTest do
  use ExUnit.Case, async: true

  alias MTProto.Telegram.RPCError
  alias MTProto.Telegram.Result
  alias MTProto.TL
  alias MTProto.TL.Runtime
  alias MTProto.TL.Runtime.Decoded

  test "decodes rpc_error using the vendored mtproto schema" do
    binary =
      <<0x2144CA19::little-unsigned-32, TL.encode_int(420)::binary,
        TL.encode_bytes("FLOOD_WAIT_1")::binary>>

    assert {:ok,
            %Decoded{
              tl_name: "rpc_error",
              type_name: "RpcError",
              fields: %{error_code: 420, error_message: "FLOOD_WAIT_1"}
            }, <<>>} = Runtime.decode(binary)
  end

  test "unwraps gzip_packed API results" do
    packed_inner =
      <<0x2144CA19::little-unsigned-32, TL.encode_int(303)::binary,
        TL.encode_bytes("SEE_OTHER")::binary>>

    binary =
      <<0x3072CFA1::little-unsigned-32,
        TL.encode_bytes(:zlib.gzip(packed_inner))::binary>>

    assert {:ok,
            %Decoded{
              tl_name: "gzip_packed",
              fields: %{
                packed_data: _packed_data,
                unpacked_data: ^packed_inner,
                unpacked: %Decoded{
                  tl_name: "rpc_error",
                  fields: %{error_code: 303, error_message: "SEE_OTHER"}
                }
              }
            }} = Result.decode(binary)
  end

  test "allows rpc_error when a concrete result type is expected" do
    binary =
      <<0x2144CA19::little-unsigned-32, TL.encode_int(420)::binary,
        TL.encode_bytes("FLOOD_WAIT_1")::binary>>

    assert {:ok,
            %Decoded{
              tl_name: "rpc_error",
              type_name: "RpcError",
              fields: %{error_code: 420, error_message: "FLOOD_WAIT_1"}
            }} = Result.decode(binary, type: "Config")
  end

  test "unwraps gzip_packed rpc_error when a concrete result type is expected" do
    packed_inner =
      <<0x2144CA19::little-unsigned-32, TL.encode_int(500)::binary,
        TL.encode_bytes("INTERNAL")::binary>>

    binary =
      <<0x3072CFA1::little-unsigned-32,
        TL.encode_bytes(:zlib.gzip(packed_inner))::binary>>

    assert {:ok,
            %Decoded{
              tl_name: "gzip_packed",
              fields: %{
                unpacked: %Decoded{
                  tl_name: "rpc_error",
                  fields: %{error_code: 500, error_message: "INTERNAL"}
                }
              }
            }} = Result.decode(binary, type: "Config")
  end

  test "extracts structured rpc_error metadata" do
    decoded = %Decoded{
      tl_name: "rpc_error",
      type_name: "RpcError",
      fields: %{error_code: 420, error_message: "FLOOD_WAIT_12"}
    }

    assert {:ok,
            %RPCError{
              code: 420,
              message: "FLOOD_WAIT_12",
              name: "FLOOD_WAIT",
              value: 12,
              wait_seconds: 12,
              migrate_to_dc: nil
            }} = Result.rpc_error(decoded)
  end

  test "extracts migrate target from gzip_packed rpc_error" do
    decoded = %Decoded{
      tl_name: "gzip_packed",
      fields: %{
        unpacked: %Decoded{
          tl_name: "rpc_error",
          type_name: "RpcError",
          fields: %{error_code: 303, error_message: "PHONE_MIGRATE_4"}
        }
      }
    }

    assert {:ok,
            %RPCError{
              code: 303,
              message: "PHONE_MIGRATE_4",
              name: "PHONE_MIGRATE",
              value: 4,
              wait_seconds: nil,
              migrate_to_dc: 4
            }} = Result.rpc_error(decoded)
  end

  test "decodes current user constructor from vendored telegram schema" do
    binary =
      <<0x020B1422::little-unsigned-32, TL.encode_int(0)::binary,
        TL.encode_int(0)::binary, TL.encode_long(42)::binary>>

    assert {:ok,
            %Decoded{
              tl_name: "user",
              type_name: "User",
              constructor_id: 0x020B1422,
              fields: %{flags: 0, flags2: 0, id: 42}
            }, <<>>} = Runtime.decode(binary, type: "User")
  end

  test "decodes current userFull constructor from official telegram json schema" do
    binary =
      <<0xC577B5AD::little-unsigned-32, TL.encode_int(0)::binary,
        TL.encode_int(0)::binary, TL.encode_long(42)::binary,
        0xF47741F7::little-unsigned-32, TL.encode_int(0)::binary,
        0x99622C0C::little-unsigned-32, TL.encode_int(0)::binary,
        TL.encode_int(0)::binary>>

    assert {:ok,
            %Decoded{
              tl_name: "userFull",
              type_name: "UserFull",
              constructor_id: 0xC577B5AD,
              fields: %{
                flags: 0,
                flags2: 0,
                id: 42,
                common_chats_count: 0,
                settings: %Decoded{
                  tl_name: "peerSettings",
                  fields: %{flags: 0}
                },
                notify_settings: %Decoded{
                  tl_name: "peerNotifySettings",
                  fields: %{flags: 0}
                }
              }
            }, <<>>} = Runtime.decode(binary, type: "UserFull")
  end
end
