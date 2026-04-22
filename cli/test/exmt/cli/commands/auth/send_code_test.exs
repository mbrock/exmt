defmodule Exmt.CLI.Commands.Auth.SendCodeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.Auth.SendCode

  test "rejects invalid switches" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_switches, [{"--wat", nil}]}} =
                 SendCode.run(["+15551234567", "--wat"])
      end)

    assert io =~ "--wat"
    assert io =~ "exmt auth send-code"
  end

  test "requires a phone number argument" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:missing_argument, "<phone-number>"}} =
                 SendCode.run([])
      end)

    assert io =~ "<phone-number>"
    assert io =~ "exmt auth send-code"
  end
end
