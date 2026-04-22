defmodule Exmt.CLI.Commands.WhoamiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.Whoami

  test "rejects invalid switches" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_switches, [{"--wat", nil}]}} =
                 Whoami.run(["--wat"])
      end)

    assert io =~ "--wat"
    assert io =~ "exmt whoami"
  end

  test "rejects unexpected positional arguments" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:unexpected_arguments, ["extra"]}} =
                 Whoami.run(["extra"])
      end)

    assert io =~ "[\"extra\"]"
    assert io =~ "exmt whoami"
  end
end
