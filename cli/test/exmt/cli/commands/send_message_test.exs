defmodule Exmt.CLI.Commands.SendMessageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.SendMessage

  test "requires a message argument" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:missing_argument, "<message>"}} =
                 SendMessage.run([])
      end)

    assert io =~ "<message>"
    assert io =~ "exmt send-message"
  end
end
