defmodule Exmt.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints top-level usage with no command" do
    output =
      capture_io(fn ->
        assert :ok = Exmt.CLI.run([])
      end)

    assert output =~ "usage:"
    assert output =~ "get-config"
    assert output =~ "get-nearest-dc"
    assert output =~ "whoami"
    assert output =~ "contacts"
    assert output =~ "dialogs"
    assert output =~ "history"
    assert output =~ "send-message"
    assert output =~ "follow"
    assert output =~ "auth send-code"
  end

  test "prints command usage via help" do
    output =
      capture_io(fn ->
        assert :ok = Exmt.CLI.run(["help", "get-config"])
      end)

    assert output =~ "exmt get-config"
  end

  test "prints subcommand usage via help" do
    output =
      capture_io(fn ->
        assert :ok = Exmt.CLI.run(["help", "auth"])
      end)

    assert output =~ "exmt auth <subcommand>"
    assert output =~ "auth send-code"
    assert output =~ "auth sign-in"
  end

  test "returns an error for unknown commands" do
    error_output =
      capture_io(:stderr, fn ->
        assert {:error, {:unknown_command, ["wat"]}} = Exmt.CLI.run(["wat"])
      end)

    assert error_output =~ "unknown command"
  end
end
