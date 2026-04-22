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

  @type pushed_result :: %{
          state: UpdateState.t(),
          top_level: Decoded.t(),
          items: [item()],
          context: context()
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

  @spec apply_pushed(UpdateState.t(), term()) ::
          {:ok, pushed_result()}
          | {:reconcile, UpdateState.t()}
          | {:error, term()}
  def apply_pushed(%UpdateState{} = state, %Decoded{
        tl_name: "updatesTooLong"
      }) do
    {:reconcile, state}
  end

  def apply_pushed(
        %UpdateState{} = state,
        %Decoded{
          tl_name: "updateShort",
          fields: %{update: %Decoded{} = update, date: date}
        } = decoded
      ) do
    if reconcile_update?(update) do
      {:reconcile, state}
    else
      with {:ok, next_state} <-
             merge_state(
               state,
               state_attrs_from_update(update)
               |> put_state_attr(:date, date)
             ) do
        {:ok,
         %{
           state: next_state,
           top_level: decoded,
           items: [{:update, update}],
           context: empty_context()
         }}
      end
    end
  end

  def apply_pushed(
        %UpdateState{} = state,
        %Decoded{
          tl_name: tl_name,
          fields: fields
        } = decoded
      )
      when tl_name in [
             "updateShortMessage",
             "updateShortChatMessage",
             "updateShortSentMessage"
           ] do
    with {:ok, next_state} <-
           merge_state(
             state,
             %{}
             |> put_state_attr(:pts, Map.get(fields, :pts))
             |> put_state_attr(:date, Map.get(fields, :date))
           ) do
      {:ok,
       %{
         state: next_state,
         top_level: decoded,
         items: [{:update, decoded}],
         context: empty_context()
       }}
    end
  end

  def apply_pushed(
        %UpdateState{} = state,
        %Decoded{
          tl_name: "updatesCombined",
          fields: fields
        } = decoded
      ) do
    updates = Map.get(fields, :updates, [])

    cond do
      sequence_gap?(state, Map.get(fields, :seq_start)) ->
        {:reconcile, state}

      Enum.any?(updates, &reconcile_update?/1) ->
        {:reconcile, state}

      true ->
        with {:ok, next_state} <-
               merge_state(
                 state,
                 state_attrs_from_updates(updates)
                 |> put_state_attr(:date, Map.get(fields, :date))
                 |> put_state_attr(:seq, Map.get(fields, :seq))
               ) do
          {:ok,
           %{
             state: next_state,
             top_level: decoded,
             items: Enum.map(updates, &{:update, &1}),
             context: updates_context(fields)
           }}
        end
    end
  end

  def apply_pushed(
        %UpdateState{} = state,
        %Decoded{
          tl_name: "updates",
          fields: fields
        } = decoded
      ) do
    updates = Map.get(fields, :updates, [])

    if Enum.any?(updates, &reconcile_update?/1) do
      {:reconcile, state}
    else
      with {:ok, next_state} <-
             merge_state(
               state,
               state_attrs_from_updates(updates)
               |> put_state_attr(:date, Map.get(fields, :date))
               |> put_state_attr(:seq, Map.get(fields, :seq))
             ) do
        {:ok,
         %{
           state: next_state,
           top_level: decoded,
           items: Enum.map(updates, &{:update, &1}),
           context: updates_context(fields)
         }}
      end
    end
  end

  def apply_pushed(_state, _decoded),
    do: {:error, :invalid_updates}

  defp difference_items(fields) do
    Enum.map(Map.get(fields, :new_messages, []), &{:message, &1}) ++
      Enum.map(
        Map.get(fields, :new_encrypted_messages, []),
        &{:encrypted_message, &1}
      ) ++
      Enum.map(Map.get(fields, :other_updates, []), &{:update, &1})
  end

  defp difference_context(fields) do
    updates_context(fields)
  end

  defp updates_context(fields) do
    %{
      users: Map.get(fields, :users, []),
      chats: Map.get(fields, :chats, [])
    }
  end

  defp empty_context do
    %{users: [], chats: []}
  end

  defp state_attrs_from_updates(updates) when is_list(updates) do
    Enum.reduce(updates, %{}, fn update, attrs ->
      merge_state_attrs(attrs, state_attrs_from_update(update))
    end)
  end

  defp state_attrs_from_update(%Decoded{fields: fields}) do
    %{}
    |> put_state_attr(:pts, Map.get(fields, :pts))
    |> put_state_attr(:qts, Map.get(fields, :qts))
    |> put_state_attr(:date, Map.get(fields, :date))
    |> put_state_attr(:seq, Map.get(fields, :seq))
  end

  defp state_attrs_from_update(_decoded), do: %{}

  defp merge_state_attrs(left, right) do
    Enum.reduce([:pts, :qts, :date, :seq], left, fn key, acc ->
      put_state_attr(acc, key, Map.get(right, key))
    end)
  end

  defp put_state_attr(attrs, _key, nil), do: attrs

  defp put_state_attr(attrs, key, value)
       when is_integer(value) and value >= 0 do
    Map.update(attrs, key, value, &max(&1, value))
  end

  defp put_state_attr(attrs, _key, _value), do: attrs

  defp merge_state(%UpdateState{} = state, attrs) do
    with {:ok, pts} <- merge_state_value(state.pts, Map.get(attrs, :pts)),
         {:ok, qts} <- merge_state_value(state.qts, Map.get(attrs, :qts)),
         {:ok, date} <- merge_state_value(state.date, Map.get(attrs, :date)),
         {:ok, seq} <- merge_state_value(state.seq, Map.get(attrs, :seq)) do
      {:ok, %UpdateState{state | pts: pts, qts: qts, date: date, seq: seq}}
    end
  end

  defp merge_state_value(current, nil), do: {:ok, current}

  defp merge_state_value(current, value)
       when is_integer(value) and value >= 0 do
    {:ok, max(current, value)}
  end

  defp merge_state_value(_current, _value),
    do: {:error, :invalid_updates_state}

  defp reconcile_update?(%Decoded{tl_name: "updatePtsChanged"}), do: true
  defp reconcile_update?(_update), do: false

  defp sequence_gap?(%UpdateState{seq: current_seq}, seq_start)
       when is_integer(seq_start) and seq_start > current_seq + 1,
       do: true

  defp sequence_gap?(_state, _seq_start), do: false
end
