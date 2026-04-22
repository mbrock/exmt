defmodule Exmt.CLI.Commands.HistoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.History

  test "rejects invalid peer format" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_peer, "wat"}} =
                 History.run(["--peer", "wat"])
      end)

    assert io =~ "invalid --peer"
    assert io =~ "exmt history"
  end
end
