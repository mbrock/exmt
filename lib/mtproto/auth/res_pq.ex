defmodule MTProto.Auth.ResPQ do
  @moduledoc false

  @enforce_keys [:nonce, :server_nonce, :pq, :server_public_key_fingerprints]
  defstruct [:nonce, :server_nonce, :pq, :server_public_key_fingerprints]

  @type t :: %__MODULE__{
          nonce: binary(),
          server_nonce: binary(),
          pq: binary(),
          server_public_key_fingerprints: [non_neg_integer()]
        }
end
