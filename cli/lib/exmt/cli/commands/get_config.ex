defmodule Exmt.CLI.Commands.GetConfig do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["get-config"],
    builder: :help_get_config
end
