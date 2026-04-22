defmodule MTProto.Telegram.Updates do
  @moduledoc """
  Pure helpers for interpreting decoded Telegram updates state and differences.
  """

  alias MTProto.Telegram.UpdateState
  alias MTProto.TL.Runtime.Decoded

  @type item ::
          {:message, Decoded.t()}
          | {:encrypted_message, Decoded.t()}
          | {:update, Decoded.t()}

  @type context :: %{users: [Decoded.t()], chats: [Decoded.t()]}

  @type difference_result :: %{
          state: UpdateState.t(),
          items: [item()],
          context: context(),
          final?: boolean()
        }

  @spec apply_difference(UpdateState.t(), term()) ::
          {:ok, difference_result()}
          | {:reset, UpdateState.t()}
          | {:error, term()}
  def apply_difference(%UpdateState{} = state, %Decoded{
        tl_name: "updates.differenceEmpty",
        fields: fields
      }) do
    {:ok,
     %{
       state: %UpdateState{state | date: fields.date, seq: fields.seq},
       items: [],
       context: %{users: [], chats: []},
       final?: true
     }}
  end

  def apply_difference(_state, %Decoded{
        tl_name: "updates.difference",
        fields: fields
      }) do
    with {:ok, next_state} <- UpdateState.from_decoded(fields.state) do
      {:ok,
       %{
         state: next_state,
         items: difference_items(fields),
         context: difference_context(fields),
         final?: true
       }}
    end
  end

  def apply_difference(_state, %Decoded{
        tl_name: "updates.differenceSlice",
        fields: fields
      }) do
    with {:ok, next_state} <-
           UpdateState.from_decoded(fields.intermediate_state) do
      {:ok,
       %{
         state: next_state,
         items: difference_items(fields),
         context: difference_context(fields),
         final?: false
       }}
    end
  end

  def apply_difference(%UpdateState{} = state, %Decoded{
        tl_name: "updates.differenceTooLong",
        fields: fields
      }) do
    {:reset, %UpdateState{state | pts: fields.pts}}
  end

  def apply_difference(_state, _decoded),
    do: {:error, :invalid_updates_difference}

  defp difference_items(fields) do
    Enum.map(Map.get(fields, :new_messages, []), &{:message, &1}) ++
      Enum.map(
        Map.get(fields, :new_encrypted_messages, []),
        &{:encrypted_message, &1}
      ) ++
      Enum.map(Map.get(fields, :other_updates, []), &{:update, &1})
  end

  defp difference_context(fields) do
    %{
      users: Map.get(fields, :users, []),
      chats: Map.get(fields, :chats, [])
    }
  end
end
