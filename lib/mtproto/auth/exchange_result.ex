defmodule MTProto.Auth.ExchangeResult do
  @moduledoc false

  @enforce_keys [:auth_key, :server_salt, :time_offset]
  defstruct [:auth_key, :server_salt, :time_offset]

  @type t :: %__MODULE__{
          auth_key: MTProto.AuthKey.t(),
          server_salt: integer(),
          time_offset: integer()
        }
end
