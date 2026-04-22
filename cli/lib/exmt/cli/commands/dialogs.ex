defmodule Exmt.CLI.Commands.Dialogs do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["dialogs"],
    switches: [limit: :integer, exclude_pinned: :boolean, folder_id: :integer],
    builder: {MTProto.Telegram.API.Messages, :getDialogs},
    prepare: :prepare_request

  def prepare_request(opts, _args) do
    {:ok,
     %{
       request_opts:
         opts
         |> Keyword.take([:limit, :exclude_pinned, :folder_id])
         |> Keyword.put_new(:offset_date, 0)
         |> Keyword.put_new(:offset_id, 0)
         |> Keyword.put_new(:offset_peer, :empty)
         |> Keyword.put_new(:limit, 20)
         |> Keyword.put_new(:hash, 0)
     }}
  end
end
