defmodule MTProto.Telegram.UpdateState do
  @moduledoc """
  Durable Telegram updates state used by `updates.getDifference`.
  """

  alias MTProto.TL.Runtime.Decoded

  @version 1

  @enforce_keys [:pts, :qts, :date, :seq]
  defstruct [:pts, :qts, :date, :seq, unread_count: nil]

  @type t :: %__MODULE__{
          pts: non_neg_integer(),
          qts: non_neg_integer(),
          date: non_neg_integer(),
          seq: non_neg_integer(),
          unread_count: non_neg_integer() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, pts} <- fetch_integer_opt(opts, :pts),
         {:ok, qts} <- fetch_integer_opt(opts, :qts),
         {:ok, date} <- fetch_integer_opt(opts, :date),
         {:ok, seq} <- fetch_integer_opt(opts, :seq),
         {:ok, unread_count} <-
           fetch_optional_integer_opt(opts, :unread_count),
         :ok <- validate_non_negative(pts, :invalid_pts),
         :ok <- validate_non_negative(qts, :invalid_qts),
         :ok <- validate_non_negative(date, :invalid_date),
         :ok <- validate_non_negative(seq, :invalid_seq),
         :ok <-
           validate_optional_non_negative(unread_count, :invalid_unread_count) do
      {:ok,
       %__MODULE__{
         pts: pts,
         qts: qts,
         date: date,
         seq: seq,
         unread_count: unread_count
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, state} ->
        state

      {:error, reason} ->
        raise ArgumentError, "invalid update state: #{inspect(reason)}"
    end
  end

  @spec from_decoded(term()) :: {:ok, t()} | {:error, term()}
  def from_decoded(%Decoded{
        tl_name: "updates.state",
        fields: fields
      }) do
    new(
      pts: fields.pts,
      qts: fields.qts,
      date: fields.date,
      seq: fields.seq,
      unread_count: Map.get(fields, :unread_count)
    )
  end

  def from_decoded(_decoded), do: {:error, :invalid_updates_state}

  @spec to_difference_opts(t()) :: keyword()
  def to_difference_opts(%__MODULE__{} = state) do
    [pts: state.pts, date: state.date, qts: state.qts]
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      "version" => @version,
      "pts" => state.pts,
      "qts" => state.qts,
      "date" => state.date,
      "seq" => state.seq,
      "unread_count" => state.unread_count
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, version} <- fetch_map_value(map, :version, @version),
         :ok <- validate_version(version),
         {:ok, pts} <- fetch_map_value(map, :pts),
         {:ok, qts} <- fetch_map_value(map, :qts),
         {:ok, date} <- fetch_map_value(map, :date),
         {:ok, seq} <- fetch_map_value(map, :seq),
         {:ok, unread_count} <- fetch_map_value(map, :unread_count, nil) do
      new(
        pts: pts,
        qts: qts,
        date: date,
        seq: seq,
        unread_count: unread_count
      )
    end
  end

  def from_map(_map), do: {:error, :invalid_update_state_map}

  defp fetch_integer_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_optional_integer_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_map_value(map, key, default \\ :no_default) do
    string_key = Atom.to_string(key)

    case map do
      %{^key => value} -> {:ok, value}
      %{^string_key => value} -> {:ok, value}
      _ when default != :no_default -> {:ok, default}
      _ -> {:error, {:missing_key, key}}
    end
  end

  defp validate_version(@version), do: :ok

  defp validate_version(_version),
    do: {:error, :unsupported_update_state_version}

  defp validate_non_negative(value, _error)
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_non_negative(_value, error), do: {:error, error}

  defp validate_optional_non_negative(nil, _error), do: :ok

  defp validate_optional_non_negative(value, error),
    do: validate_non_negative(value, error)
end
