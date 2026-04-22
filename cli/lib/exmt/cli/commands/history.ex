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
    builder: {MTProto.Telegram.API.Messages, :getHistory},
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
           |> Keyword.put_new(:offset_id, 0)
           |> Keyword.put_new(:offset_date, 0)
           |> Keyword.put_new(:add_offset, 0)
           |> Keyword.put_new(:limit, 20)
           |> Keyword.put_new(:max_id, 0)
           |> Keyword.put_new(:min_id, 0)
           |> Keyword.put_new(:hash, 0)
       }}
    end
  end
end
