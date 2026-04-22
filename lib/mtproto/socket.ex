defmodule MTProto.Socket do
  @moduledoc false

  @callback connect(term(), :inet.port_number(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback send(term(), iodata()) :: :ok | {:error, term()}
  @callback setopts(term(), keyword()) :: :ok | {:error, term()}
  @callback close(term()) :: :ok
end
