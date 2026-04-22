defmodule MTProto.Auth.TCPConnection do
  @moduledoc deprecated: "Use MTProto.TCPConnection instead."

  alias MTProto.TCPConnection

  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: TCPConnection

  @spec begin_auth_key_exchange(GenServer.server(), keyword()) ::
          :ok | {:error, term()}
  defdelegate begin_auth_key_exchange(server, opts \\ []), to: TCPConnection

  @spec ping(GenServer.server(), integer(), keyword()) ::
          :ok | {:error, term()}
  defdelegate ping(server, ping_id, opts \\ []), to: TCPConnection
end
