defmodule Exmt.CLI.Commands.GetConfig do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["get-config"],
    builder: {MTProto.Telegram.API.Help, :getConfig}
end
