defmodule Exmt.CLI.Commands.Dialogs do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["dialogs"],
    switches: [limit: :integer, exclude_pinned: :boolean, folder_id: :integer],
    builder: :messages_get_dialogs,
    prepare: :prepare_request

  def prepare_request(opts, _args) do
    {:ok,
     %{
       request_opts: Keyword.take(opts, [:limit, :exclude_pinned, :folder_id])
     }}
  end
end
