defmodule MTProto do
  @moduledoc """
  Small sans-IO MTProto client core.
  """

  alias MTProto.Core

  defdelegate new(opts \\ []), to: Core
  defdelegate begin_auth_key_exchange(state, now_ns, nonce), to: Core
  defdelegate receive_bytes(state, chunk), to: Core
end
