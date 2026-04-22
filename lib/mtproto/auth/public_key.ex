defmodule MTProto.Auth.PublicKey do
  @moduledoc """
  MTProto server RSA public key metadata.
  """

  alias MTProto.TL

  @type mode :: :legacy | :padded

  @enforce_keys [:modulus, :exponent, :fingerprint, :mode]
  defstruct [:modulus, :exponent, :fingerprint, :mode]

  @type t :: %__MODULE__{
          modulus: pos_integer(),
          exponent: pos_integer(),
          fingerprint: non_neg_integer(),
          mode: mode()
        }

  @spec new(integer() | binary(), integer() | binary(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(modulus, exponent, opts \\ []) do
    with {:ok, modulus} <- normalize_integer(modulus),
         {:ok, exponent} <- normalize_integer(exponent),
         :ok <- validate_mode(Keyword.get(opts, :mode, :padded)) do
      mode = Keyword.get(opts, :mode, :padded)
      modulus_binary = :binary.encode_unsigned(modulus)
      exponent_binary = :binary.encode_unsigned(exponent)

      digest =
        :crypto.hash(
          :sha,
          TL.encode_bytes(modulus_binary) <> TL.encode_bytes(exponent_binary)
        )

      {:ok,
       %__MODULE__{
         modulus: modulus,
         exponent: exponent,
         fingerprint:
           :binary.decode_unsigned(binary_part(digest, 12, 8), :little),
         mode: mode
       }}
    end
  end

  @spec new!(integer() | binary(), integer() | binary(), keyword()) :: t()
  def new!(modulus, exponent, opts \\ []) do
    case new(modulus, exponent, opts) do
      {:ok, key} ->
        key

      {:error, reason} ->
        raise ArgumentError, "invalid public key: #{inspect(reason)}"
    end
  end

  @spec from_pem(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_pem(pem, opts \\ []) when is_binary(pem) do
    with {:ok, [entry | _]} <- decode_pem_entries(pem),
         {:RSAPublicKey, modulus, exponent} <-
           apply(:public_key, :pem_entry_decode, [entry]),
         {:ok, key} <- new(modulus, exponent, opts) do
      {:ok, key}
    else
      [] -> {:error, :invalid_pem}
      :not_found -> {:error, :invalid_pem}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_pem}
    end
  end

  @spec from_pem_many(binary(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def from_pem_many(pem, opts \\ []) when is_binary(pem) do
    with {:ok, entries} <- decode_pem_entries(pem) do
      entries
      |> Enum.map(fn entry ->
        case apply(:public_key, :pem_entry_decode, [entry]) do
          {:RSAPublicKey, modulus, exponent} -> new(modulus, exponent, opts)
          _ -> {:error, :invalid_pem}
        end
      end)
      |> collect_results()
    end
  end

  @spec select([t()], [non_neg_integer()]) ::
          {:ok, t()} | {:error, :unknown_public_key}
  def select(keys, fingerprints)
      when is_list(keys) and is_list(fingerprints) do
    Enum.find_value(
      fingerprints,
      {:error, :unknown_public_key},
      fn fingerprint ->
        Enum.find_value(keys, fn
          %__MODULE__{fingerprint: ^fingerprint} = key -> {:ok, key}
          _ -> nil
        end)
      end
    )
  end

  defp decode_pem_entries(pem) do
    case apply(:public_key, :pem_decode, [pem]) do
      [] -> {:error, :invalid_pem}
      entries -> {:ok, entries}
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, key}, {:ok, acc} -> {:cont, {:ok, [key | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_integer(value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_integer(value)
       when is_binary(value) and byte_size(value) > 0,
       do: {:ok, :binary.decode_unsigned(value)}

  defp normalize_integer(_), do: {:error, :invalid_integer}

  defp validate_mode(mode) when mode in [:legacy, :padded], do: :ok
  defp validate_mode(_), do: {:error, :invalid_mode}
end
