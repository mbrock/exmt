defmodule Exmt.CLI.Commands.Whoami do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["whoami"],
    builder: {MTProto.Telegram.API.Users, :getFullUser},
    prepare: :prepare_request

  def prepare_request(_opts, _args) do
    {:ok, %{request_opts: [id: :self]}}
  end
end
