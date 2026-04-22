defmodule Exmt.CLI.Commands.Auth.SignInTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exmt.CLI.Commands.Auth.SignIn

  test "rejects invalid switches" do
    io =
      capture_io(:stderr, fn ->
        assert {:error, {:invalid_switches, [{"--wat", nil}]}} =
                 SignIn.run(["+15551234567", "hash", "12345", "--wat"])
      end)

    assert io =~ "--wat"
    assert io =~ "exmt auth sign-in"
  end

  test "requires phone number, phone code hash, and phone code" do
    io =
      capture_io(:stderr, fn ->
        assert {:error,
                {:missing_argument,
                 "<phone-number> <phone-code-hash> <phone-code>"}} =
                 SignIn.run(["+15551234567", "hash"])
      end)

    assert io =~ "<phone-number> <phone-code-hash> <phone-code>"
    assert io =~ "exmt auth sign-in"
  end
end
