defmodule Exmt.CLI.Commands.FollowTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.Follow

  test "rejects invalid switches" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_switches, [{"--wat", nil}]}} =
                 Follow.run(["--wat"])
      end)

    assert io =~ "--wat"
    assert io =~ "exmt follow"
  end

  test "rejects unexpected positional arguments" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:unexpected_arguments, ["extra"]}} =
                 Follow.run(["extra"])
      end)

    assert io =~ "[\"extra\"]"
    assert io =~ "exmt follow"
  end
end
