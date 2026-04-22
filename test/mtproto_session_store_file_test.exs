defmodule MTProto.SessionStore.FileTest do
  use ExUnit.Case, async: true

  alias MTProto.SessionData
  alias MTProto.SessionStore.File, as: FileStore

  test "round-trips session data through a file" do
    path = tmp_path!("session.term")

    session_data =
      SessionData.new!(
        auth_key_data: MTProto.AuthExchangeSample.expected_auth_key(),
        server_salt: MTProto.AuthExchangeSample.expected_server_salt(),
        time_offset: MTProto.AuthExchangeSample.expected_time_offset(),
        dc_id: 2
      )

    assert :ok = FileStore.save(path, session_data)
    assert {:ok, ^session_data} = FileStore.load(path)

    assert {:ok, %File.Stat{mode: mode}} = Elixir.File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert :ok = FileStore.delete(path)
    assert {:ok, nil} = FileStore.load(path)
  end

  defp tmp_path!(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "exmt-store-#{System.unique_integer([:positive, :monotonic])}"
      )

    Elixir.File.rm_rf!(base)
    Elixir.File.mkdir_p!(base)
    Path.join(base, name)
  end
end
