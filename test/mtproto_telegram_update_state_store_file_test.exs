defmodule MTProto.Telegram.UpdateStateStore.FileTest do
  use ExUnit.Case, async: true

  alias MTProto.Telegram.UpdateState
  alias MTProto.Telegram.UpdateStateStore.File, as: FileStore

  test "round-trips update state through a file" do
    path = tmp_path!("updates.term")

    update_state =
      UpdateState.new!(
        pts: 10,
        qts: 20,
        date: 30,
        seq: 40,
        unread_count: 50
      )

    assert :ok = FileStore.save(path, update_state)
    assert {:ok, ^update_state} = FileStore.load(path)

    assert {:ok, %File.Stat{mode: mode}} = Elixir.File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert :ok = FileStore.delete(path)
    assert {:ok, nil} = FileStore.load(path)
  end

  defp tmp_path!(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "exmt-updates-store-#{System.unique_integer([:positive, :monotonic])}"
      )

    Elixir.File.rm_rf!(base)
    Elixir.File.mkdir_p!(base)
    Path.join(base, name)
  end
end
