defmodule MTProto.Socket.GenTCP do
  @moduledoc false

  @behaviour MTProto.Socket

  @impl true
  def connect(host, port, opts), do: :gen_tcp.connect(host, port, opts)

  @impl true
  def send(socket, data), do: :gen_tcp.send(socket, data)

  @impl true
  def setopts(socket, opts), do: :inet.setopts(socket, opts)

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end
end
