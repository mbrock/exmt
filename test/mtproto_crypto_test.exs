defmodule MTProto.CryptoVectors do
  def auth_key_0_to_255 do
    for value <- 0..255, into: <<>>, do: <<value>>
  end

  def auth_key_from_gotd do
    <<93, 46, 125, 101, 244, 158, 194, 139, 208, 41, 168, 135, 97, 234, 39,
      184, 164, 199, 159, 18, 34, 101, 37, 68, 62, 125, 124, 89, 110, 243, 48,
      53, 48, 219, 33, 7, 232, 154, 169, 151, 199, 160, 22, 74, 182, 148, 24,
      122, 222, 255, 21, 107, 214, 239, 113, 24, 161, 150, 35, 71, 117, 60,
      14, 126, 137, 160, 53, 75, 142, 195, 100, 249, 153, 126, 113, 188, 105,
      35, 251, 134, 232, 228, 52, 145, 224, 16, 96, 106, 108, 232, 69, 226,
      250, 1, 148, 9, 119, 239, 10, 163, 42, 223, 90, 151, 219, 246, 212, 40,
      236, 4, 52, 215, 23, 162, 211, 173, 25, 98, 44, 192, 88, 135, 100, 33,
      19, 199, 150, 95, 251, 134, 42, 62, 60, 203, 10, 185, 90, 221, 218, 87,
      248, 146, 69, 219, 215, 107, 73, 35, 72, 248, 233, 75, 213, 167, 192,
      224, 184, 72, 8, 82, 60, 253, 30, 168, 11, 50, 254, 154, 209, 152, 188,
      46, 16, 63, 206, 183, 213, 36, 146, 236, 192, 39, 58, 40, 103, 75, 201,
      35, 238, 229, 146, 101, 171, 23, 160, 2, 223, 31, 74, 162, 197, 155,
      129, 154, 94, 94, 29, 16, 94, 193, 23, 51, 111, 92, 118, 198, 177, 135,
      3, 125, 75, 66, 112, 206, 233, 204, 33, 7, 29, 151, 233, 188, 162, 32,
      198, 215, 176, 27, 153, 140, 242, 229, 205, 185, 165, 14, 205, 161, 133,
      42, 54, 230, 53, 105, 12, 142>>
  end

  def gotd_encrypt_vector do
    <<50, 209, 88, 110, 164, 87, 223, 200, 168, 23, 41, 212, 109, 181, 64, 25,
      162, 191, 215, 247, 68, 249, 185, 108, 79, 113, 108, 253, 196, 71, 125,
      178, 162, 193, 95, 109, 219, 133, 35, 95, 185, 85, 47, 29, 132, 7, 198,
      170, 234, 0, 204, 132, 76, 90, 27, 246, 172, 68, 183, 155, 94, 220, 42,
      35, 134, 139, 61, 96, 115, 165, 144, 153, 44, 15, 41, 117, 36, 61, 86,
      62, 161, 128, 210, 24, 238, 117, 124, 154>>
  end

  def gotd_decrypt_vector do
    <<122, 113, 131, 194, 193, 14, 79, 77, 249, 69, 250, 154, 154, 189, 53,
      231, 195, 132, 11, 97, 240, 69, 48, 79, 57, 103, 76, 25, 192, 226, 9,
      120, 79, 80, 246, 34, 106, 7, 53, 41, 214, 117, 201, 44, 191, 11, 250,
      140, 153, 167, 155, 63, 57, 199, 42, 93, 154, 2, 109, 67, 26, 183, 64,
      124, 160, 78, 204, 85, 24, 125, 108, 69, 241, 120, 113, 82, 78, 221,
      144, 206, 160, 46, 215, 40, 225, 77, 124, 177, 138, 234, 42, 99, 97, 88,
      240, 148, 89, 169, 67, 119, 16, 216, 148, 199, 159, 54, 140, 78, 129,
      100, 183, 100, 126, 169, 134, 18, 174, 254, 148, 44, 93, 146, 18, 26,
      203, 141, 176, 45, 204, 206, 182, 109, 15, 135, 32, 172, 18, 160, 109,
      176, 88, 43, 253, 149, 91, 227, 79, 54, 81, 24, 227, 186, 184, 205, 8,
      12, 230, 180, 91, 40, 234, 197, 109, 205, 42, 41, 55, 78>>
  end

  def gotd_decrypted_plaintext do
    <<252, 130, 106, 2, 36, 139, 40, 253, 96, 242, 196, 130, 36, 67, 173, 104,
      1, 240, 193, 194, 145, 139, 48, 94, 2, 0, 0, 0, 88, 0, 0, 0, 220, 248,
      241, 115, 2, 0, 0, 0, 1, 168, 193, 194, 145, 139, 48, 94, 1, 0, 0, 0,
      28, 0, 0, 0, 8, 9, 194, 158, 196, 253, 51, 173, 145, 139, 48, 94, 24,
      168, 142, 166, 7, 238, 88, 22, 252, 130, 106, 2, 36, 139, 40, 253, 1,
      204, 193, 194, 145, 139, 48, 94, 2, 0, 0, 0, 20, 0, 0, 0, 197, 115, 119,
      52, 196, 253, 51, 173, 145, 139, 48, 94, 100, 8, 48, 0, 0, 0, 0, 0, 252,
      230, 103, 4, 163, 205, 142, 233, 208, 174, 111, 171, 103, 44, 96, 192,
      74, 63, 31, 212, 73, 14, 81, 246>>
  end
end

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
              124, 103>>} =
             AuthKey.calc_new_nonce_hash(auth_key, new_nonce, 1)

    assert {:ok,
            <<244, 49, 142, 133, 189, 47, 243, 190, 132, 217, 254, 252, 227,
              220, 227, 159>>} =
             AuthKey.calc_new_nonce_hash(auth_key, new_nonce, 2)

    assert {:ok,
            <<75, 249, 215, 179, 125, 180, 19, 238, 67, 29, 40, 81, 118, 49,
              203, 61>>} =
             AuthKey.calc_new_nonce_hash(auth_key, new_nonce, 3)
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
