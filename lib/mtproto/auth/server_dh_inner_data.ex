defmodule MTProto.Auth.ServerDHInnerData do
  @moduledoc false

  @enforce_keys [:nonce, :server_nonce, :g, :dh_prime, :g_a, :server_time]
  defstruct [:nonce, :server_nonce, :g, :dh_prime, :g_a, :server_time]

  @type t :: %__MODULE__{
          nonce: binary(),
          server_nonce: binary(),
          g: integer(),
          dh_prime: binary(),
          g_a: binary(),
          server_time: integer()
        }
end
