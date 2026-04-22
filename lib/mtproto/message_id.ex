defmodule MTProto.MessageId do
  @moduledoc """
  Pure `msg_id` generation for client messages.
  """

  @fraction_scale 4_294_967_296
  @nanoseconds_per_second 1_000_000_000

  @spec next(non_neg_integer() | nil, non_neg_integer()) :: non_neg_integer()
  def next(nil, now_ns), do: from_nanoseconds(now_ns)

  def next(last_msg_id, now_ns) when is_integer(last_msg_id) and last_msg_id >= 0 do
    max(from_nanoseconds(now_ns), last_msg_id + 4)
  end

  @spec from_nanoseconds(non_neg_integer()) :: non_neg_integer()
  def from_nanoseconds(now_ns) when is_integer(now_ns) and now_ns >= 0 do
    seconds = div(now_ns, @nanoseconds_per_second)
    nanos = rem(now_ns, @nanoseconds_per_second)

    fraction =
      nanos
      |> Kernel.*(@fraction_scale)
      |> div(@nanoseconds_per_second)
      |> max(4)

    msg_id = seconds * @fraction_scale + fraction
    msg_id - rem(msg_id, 4)
  end
end
