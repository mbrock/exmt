defmodule Exmt.CLI.Commands.GetNearestDC do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["get-nearest-dc"],
    builder: :help_get_nearest_dc
end
