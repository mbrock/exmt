defmodule Exmt.CLI.Commands.GetConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.GetConfig

  test "rejects invalid switches" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_switches, [{"--wat", nil}]}} =
                 GetConfig.run(["--wat"])
      end)

    assert io =~ "--wat"
    assert io =~ "exmt get-config"
  end

  test "rejects unexpected positional arguments" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:unexpected_arguments, ["extra"]}} =
                 GetConfig.run(["extra"])
      end)

    assert io =~ "[\"extra\"]"
    assert io =~ "exmt get-config"
  end
end
