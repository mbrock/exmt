defmodule Exmt.CLI.Commands.History do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["history"],
    switches: [
      peer: :string,
      limit: :integer,
      offset_id: :integer,
      offset_date: :integer,
      add_offset: :integer,
      max_id: :integer,
      min_id: :integer
    ],
    builder: :messages_get_history,
    prepare: :prepare_request

  def prepare_request(opts, _args) do
    with {:ok, peer} <- Exmt.CLI.Command.parse_peer_opt(opts) do
      {:ok,
       %{
         request_opts:
           opts
           |> Keyword.take([
             :limit,
             :offset_id,
             :offset_date,
             :add_offset,
             :max_id,
             :min_id
           ])
           |> Keyword.put(:peer, peer)
       }}
    end
  end
end
