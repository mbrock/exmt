defmodule MTProto.Telegram.Request do
  @moduledoc false

  @enforce_keys [:query]
  defstruct [:query, request: :telegram_request, result_type: nil]

  @type t :: %__MODULE__{
          query: binary(),
          request: term(),
          result_type: binary() | atom() | nil
        }

  @spec new(binary(), term(), binary() | atom() | nil) :: t()
  def new(query, request \\ :telegram_request, result_type \\ nil)
      when is_binary(query) do
    %__MODULE__{
      query: query,
      request: request,
      result_type: result_type
    }
  end
end
