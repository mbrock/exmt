defmodule MTProto.AuthKey do
  @moduledoc """
  Authorization key metadata derived from the 2048-bit MTProto auth key.
  """

  @enforce_keys [:data, :aux_hash, :id]
  defstruct [:data, :aux_hash, :id]

  @type t :: %__MODULE__{
          data: binary(),
          aux_hash: binary(),
          id: binary()
        }

  @spec new(binary()) :: {:ok, t()} | {:error, :invalid_auth_key_length}
  def new(data) when is_binary(data) and byte_size(data) == 256 do
    digest = :crypto.hash(:sha, data)

    {:ok,
     %__MODULE__{
       data: data,
       aux_hash: binary_part(digest, 0, 8),
       id: binary_part(digest, 12, 8)
     }}
  end

  def new(_), do: {:error, :invalid_auth_key_length}

  @spec new!(binary()) :: t()
  def new!(data) do
    case new(data) do
      {:ok, auth_key} ->
        auth_key

      {:error, reason} ->
        raise ArgumentError, "invalid auth key: #{inspect(reason)}"
    end
  end

  @spec id_integer(t()) :: non_neg_integer()
  def id_integer(%__MODULE__{id: id}) do
    :binary.decode_unsigned(id, :little)
  end

  @spec calc_new_nonce_hash(t(), binary(), 1 | 2 | 3) ::
          {:ok, binary()} | {:error, term()}
  def calc_new_nonce_hash(%__MODULE__{aux_hash: aux_hash}, new_nonce, number)
      when is_binary(new_nonce) and byte_size(new_nonce) == 32 and
             number in 1..3 do
    digest = :crypto.hash(:sha, new_nonce <> <<number>> <> aux_hash)
    {:ok, binary_part(digest, 4, 16)}
  end

  def calc_new_nonce_hash(%__MODULE__{}, _new_nonce, _number),
    do: {:error, :invalid_new_nonce}
end
