defmodule MTProto.Telegram.UpdateStateTest do
  use ExUnit.Case, async: true

  alias MTProto.Telegram.UpdateState
  alias MTProto.TL.Runtime.Decoded

  test "round-trips update state through map form" do
    update_state =
      UpdateState.new!(
        pts: 10,
        qts: 20,
        date: 30,
        seq: 40,
        unread_count: 50
      )

    assert {:ok, ^update_state} =
             update_state
             |> UpdateState.to_map()
             |> UpdateState.from_map()
  end

  test "builds update state from decoded updates.state" do
    decoded = %Decoded{
      tl_name: "updates.state",
      fields: %{
        pts: 10,
        qts: 20,
        date: 30,
        seq: 40,
        unread_count: 50
      }
    }

    assert {:ok,
            %UpdateState{
              pts: 10,
              qts: 20,
              date: 30,
              seq: 40,
              unread_count: 50
            }} = UpdateState.from_decoded(decoded)
  end
end
