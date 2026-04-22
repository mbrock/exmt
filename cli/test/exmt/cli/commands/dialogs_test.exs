defmodule Exmt.CLI.Commands.DialogsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.Dialogs

  test "rejects invalid switches" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_switches, [{"--wat", nil}]}} =
                 Dialogs.run(["--wat"])
      end)

    assert io =~ "--wat"
    assert io =~ "exmt dialogs"
  end
end
