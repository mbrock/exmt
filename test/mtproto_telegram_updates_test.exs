defmodule MTProto.Telegram.UpdatesTest do
  use ExUnit.Case, async: true

  alias MTProto.Telegram.{UpdateState, Updates}
  alias MTProto.TL.Runtime.Decoded

  test "applies updates.difference and returns the next state and items" do
    current_state = UpdateState.new!(pts: 1, qts: 2, date: 3, seq: 4)

    decoded = %Decoded{
      tl_name: "updates.difference",
      fields: %{
        new_messages: [
          %Decoded{
            tl_name: "message",
            fields: %{id: 100, message: "hello"}
          }
        ],
        new_encrypted_messages: [],
        other_updates: [
          %Decoded{tl_name: "updateUserStatus", fields: %{user_id: 42}}
        ],
        chats: [
          %Decoded{tl_name: "channel", fields: %{id: 7, title: "exmt"}}
        ],
        users: [
          %Decoded{tl_name: "user", fields: %{id: 42, first_name: "M"}}
        ],
        state: %Decoded{
          tl_name: "updates.state",
          fields: %{pts: 11, qts: 22, date: 33, seq: 44, unread_count: 55}
        }
      }
    }

    assert {:ok, result} = Updates.apply_difference(current_state, decoded)

    assert result.final? == true

    assert result.state ==
             UpdateState.new!(
               pts: 11,
               qts: 22,
               date: 33,
               seq: 44,
               unread_count: 55
             )

    assert result.items == [
             {:message,
              %Decoded{
                tl_name: "message",
                fields: %{id: 100, message: "hello"}
              }},
             {:update,
              %Decoded{tl_name: "updateUserStatus", fields: %{user_id: 42}}}
           ]

    assert result.context.users == [
             %Decoded{tl_name: "user", fields: %{id: 42, first_name: "M"}}
           ]

    assert result.context.chats == [
             %Decoded{tl_name: "channel", fields: %{id: 7, title: "exmt"}}
           ]
  end

  test "resets on updates.differenceTooLong" do
    current_state = UpdateState.new!(pts: 1, qts: 2, date: 3, seq: 4)

    decoded = %Decoded{
      tl_name: "updates.differenceTooLong",
      fields: %{pts: 99}
    }

    assert {:reset, %UpdateState{pts: 99, qts: 2, date: 3, seq: 4}} =
             Updates.apply_difference(current_state, decoded)
  end

  test "applies updateShortMessage and advances pts/date" do
    current_state = UpdateState.new!(pts: 1, qts: 2, date: 3, seq: 4)

    decoded = %Decoded{
      tl_name: "updateShortMessage",
      fields: %{
        id: 10,
        user_id: 42,
        message: "hello",
        pts: 11,
        pts_count: 1,
        date: 33
      }
    }

    assert {:ok, result} = Updates.apply_pushed(current_state, decoded)

    assert result.top_level == decoded
    assert result.items == [{:update, decoded}]
    assert result.context == %{users: [], chats: []}

    assert result.state ==
             UpdateState.new!(pts: 11, qts: 2, date: 33, seq: 4)
  end

  test "reconciles when updatesCombined starts after the current seq" do
    current_state = UpdateState.new!(pts: 1, qts: 2, date: 3, seq: 4)

    decoded = %Decoded{
      tl_name: "updatesCombined",
      fields: %{
        updates: [],
        users: [],
        chats: [],
        date: 5,
        seq_start: 7,
        seq: 8
      }
    }

    assert {:reconcile, ^current_state} =
             Updates.apply_pushed(current_state, decoded)
  end

  test "reconciles when updateShort wraps updatePtsChanged" do
    current_state = UpdateState.new!(pts: 1, qts: 2, date: 3, seq: 4)

    decoded = %Decoded{
      tl_name: "updateShort",
      fields: %{
        update: %Decoded{tl_name: "updatePtsChanged", fields: %{}},
        date: 33
      }
    }

    assert {:reconcile, ^current_state} =
             Updates.apply_pushed(current_state, decoded)
  end
end
