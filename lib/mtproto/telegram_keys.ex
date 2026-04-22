defmodule MTProto.TelegramKeys do
  @moduledoc """
  Bundled Telegram RSA public keys used during MTProto auth-key exchange.

  We keep both the historical sample/test key used in Telegram's auth examples
  and the current production key used by real clients.
  """

  alias MTProto.Auth.PublicKey

  @sample_pem """
  -----BEGIN RSA PUBLIC KEY-----
  MIIBCgKCAQEAyMEdY1aR+sCR3ZSJrtztKTKqigvO/vBfqACJLZtS7QMgCGXJ6XIR
  yy7mx66W0/sOFa7/1mAZtEoIokDP3ShoqF4fVNb6XeqgQfaUHd8wJpDWHcR2OFwv
  plUUI1PLTktZ9uW2WE23b+ixNwJjJGwBDJPQEQFBE+vfmH0JP503wr5INS1poWg/
  j25sIWeYPHYeOrFp/eXaqhISP6G+q2IeTaWTXpwZj4LzXq5YOpk4bYEQ6mvRq7D1
  aHWfYmlEGepfaYR8Q0YqvvhYtMte3ITnuSJs171+GDqpdKcSwHnd6FudwGO4pcCO
  j4WcDuXc2CTHgH8gFTNhp/Y8/SpDOhvn9QIDAQAB
  -----END RSA PUBLIC KEY-----
  """

  @main_pem """
  -----BEGIN RSA PUBLIC KEY-----
  MIIBCgKCAQEA6LszBcC1LGzyr992NzE0ieY+BSaOW622Aa9Bd4ZHLl+TuFQ4lo4g
  5nKaMBwK/BIb9xUfg0Q29/2mgIR6Zr9krM7HjuIcCzFvDtr+L0GQjae9H0pRB2OO
  62cECs5HKhT5DZ98K33vmWiLowc621dQuwKWSQKjWf50XYFw42h21P2KXUGyp2y/
  +aEyZ+uVgLLQbRA1dEjSDZ2iGRy12Mk5gpYc397aYp438fsJoHIgJ2lgMv5h7WY9
  t6N/byY9Nw9p21Og3AoXSL2q/2IJ1WRUhebgAdGVMlV1fkuOQoEzR7EdpqtQD9Cs
  5+bfo3Nhmcyvk5ftB0WkJ9z6bNZ7yxrP8wIDAQAB
  -----END RSA PUBLIC KEY-----
  """

  @spec sample_pem() :: binary()
  def sample_pem, do: @sample_pem

  @spec main_pem() :: binary()
  def main_pem, do: @main_pem

  @spec all_pems() :: binary()
  def all_pems, do: @sample_pem <> "\n" <> @main_pem

  @spec rsa_pad_test_pem() :: binary()
  def rsa_pad_test_pem, do: @main_pem

  @spec sample_keys!() :: [PublicKey.t()]
  def sample_keys! do
    case PublicKey.from_pem_many(@sample_pem) do
      {:ok, keys} ->
        keys

      {:error, reason} ->
        raise ArgumentError, "invalid sample keys: #{inspect(reason)}"
    end
  end

  @spec main_keys!() :: [PublicKey.t()]
  def main_keys! do
    case PublicKey.from_pem_many(@main_pem) do
      {:ok, keys} ->
        keys

      {:error, reason} ->
        raise ArgumentError, "invalid main keys: #{inspect(reason)}"
    end
  end
end
