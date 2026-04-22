defmodule Exmt.CLI.Commands.GetNearestDC do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["get-nearest-dc"],
    builder: {MTProto.Telegram.API.Help, :getNearestDc}
end
