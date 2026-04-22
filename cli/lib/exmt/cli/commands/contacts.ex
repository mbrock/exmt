defmodule Exmt.CLI.Commands.Contacts do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["contacts"],
    builder: {MTProto.Telegram.API.Contacts, :getContacts},
    prepare: :prepare_request

  def prepare_request(_opts, _args) do
    {:ok, %{request_opts: [hash: 0]}}
  end
end
