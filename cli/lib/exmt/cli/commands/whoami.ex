defmodule Exmt.CLI.Commands.Whoami do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["whoami"],
    builder: :users_get_self
end
