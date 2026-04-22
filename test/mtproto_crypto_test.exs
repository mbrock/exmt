defmodule MTProto.AuthKeyTest do
  use ExUnit.Case, async: true

  alias MTProto.AuthKey

  test "derives auth_key metadata from raw key bytes" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    assert auth_key.aux_hash == <<73, 22, 214, 189, 183, 247, 142, 104>>
    assert auth_key.id == <<50, 209, 88, 110, 164, 87, 223, 200>>
    assert AuthKey.id_integer(auth_key) == 14_474_384_091_129_631_026
  end

  test "calculates new nonce hashes" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    new_nonce =
      MTProto.CryptoVectors.auth_key_0_to_255() |> binary_part(0, 32)

    assert {:ok,
            <<194, 206, 210, 179, 62, 89, 58, 85, 210, 127, 74, 93, 171, 238,
              124,
              103>>} = AuthKey.calc_new_nonce_hash(auth_key, new_nonce, 1)

    assert {:ok,
            <<244, 49, 142, 133, 189, 47, 243, 190, 132, 217, 254, 252, 227,
              220, 227,
              159>>} = AuthKey.calc_new_nonce_hash(auth_key, new_nonce, 2)

    assert {:ok,
            <<75, 249, 215, 179, 125, 180, 19, 238, 67, 29, 40, 81, 118, 49,
              203, 61>>} = AuthKey.calc_new_nonce_hash(auth_key, new_nonce, 3)
  end
end

defmodule MTProto.CryptoTest do
  use ExUnit.Case, async: true

  alias MTProto.{AuthKey, Crypto}

  test "encrypts a padded payload with the gotd reference vector" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    plaintext =
      "Hello, world! This data should remain secure!" <>
        :binary.copy(<<0>>, 19)

    assert {:ok, encrypted} =
             Crypto.encrypt_padded(plaintext, auth_key, :client)

    assert encrypted == MTProto.CryptoVectors.gotd_encrypt_vector()
  end

  test "decrypts a server payload with the gotd reference vector" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_from_gotd())

    assert {:ok, plaintext} =
             Crypto.decrypt_padded(
               MTProto.CryptoVectors.gotd_decrypt_vector(),
               auth_key,
               :server
             )

    assert plaintext == MTProto.CryptoVectors.gotd_decrypted_plaintext()
  end
end

defmodule MTProto.EncryptedPacketTest do
  use ExUnit.Case, async: true

  alias MTProto.{AuthKey, EncryptedPacket}

  test "decodes a full encrypted packet from the gotd reference vector" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_from_gotd())

    assert {:ok, packet} =
             EncryptedPacket.decode(
               MTProto.CryptoVectors.gotd_decrypt_vector(),
               auth_key,
               sender: :server
             )

    assert packet == %EncryptedPacket{
             salt: -204_760_796_269_739_268,
             session_id: 7_542_758_775_007_277_664,
             message_id: 6_787_078_096_601_346_049,
             seq_no: 2,
             body:
               <<220, 248, 241, 115, 2, 0, 0, 0, 1, 168, 193, 194, 145, 139,
                 48, 94, 1, 0, 0, 0, 28, 0, 0, 0, 8, 9, 194, 158, 196, 253,
                 51, 173, 145, 139, 48, 94, 24, 168, 142, 166, 7, 238, 88, 22,
                 252, 130, 106, 2, 36, 139, 40, 253, 1, 204, 193, 194, 145,
                 139, 48, 94, 2, 0, 0, 0, 20, 0, 0, 0, 197, 115, 119, 52, 196,
                 253, 51, 173, 145, 139, 48, 94, 100, 8, 48, 0, 0, 0, 0, 0>>,
             padding:
               <<252, 230, 103, 4, 163, 205, 142, 233, 208, 174, 111, 171,
                 103, 44, 96, 192, 74, 63, 31, 212, 73, 14, 81, 246>>
           }
  end

  test "encodes and decodes a packet with deterministic padding bytes" do
    auth_key = AuthKey.new!(MTProto.CryptoVectors.auth_key_0_to_255())

    packet = %EncryptedPacket{
      salt: 42,
      session_id: 123,
      message_id: 456,
      seq_no: 1,
      body: <<1, 2, 3, 4, 5, 6, 7, 8>>
    }

    padding_bytes = :binary.copy(<<0xAA>>, 64)

    assert {:ok, encrypted} =
             EncryptedPacket.encode(packet, auth_key,
               sender: :client,
               padding_bytes: padding_bytes
             )

    assert {:ok, decoded} =
             EncryptedPacket.decode(encrypted, auth_key,
               sender: :client,
               session_id: 123
             )

    assert decoded == %{packet | padding: :binary.copy(<<0xAA>>, 24)}
  end
end
