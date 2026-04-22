defmodule Exmt.CLI.Commands.SendMessage do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["send-message"],
    switches: [
      peer: :string,
      random_id: :integer,
      silent: :boolean,
      no_webpage: :boolean
    ],
    positionals: [:message],
    builder: :messages_send_message,
    call_args: [:message],
    prepare: :prepare_request

  def prepare_request(opts, _args) do
    with {:ok, peer} <- Exmt.CLI.Command.parse_peer_opt(opts) do
      {:ok,
       %{
         request_opts:
           opts
           |> Keyword.take([:silent, :no_webpage, :random_id])
           |> Keyword.put(:peer, peer)
           |> Keyword.put_new_lazy(:random_id, fn ->
             System.unique_integer([:positive, :monotonic])
           end)
       }}
    end
  end
end
