defmodule MTProto.Connection do
  @moduledoc deprecated: "Use MTProto.Auth.TCPConnection instead."

  alias MTProto.Auth.TCPConnection

  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: TCPConnection

  @spec begin_auth_key_exchange(GenServer.server(), keyword()) ::
          :ok | {:error, term()}
  defdelegate begin_auth_key_exchange(server, opts \\ []), to: TCPConnection
end
