defmodule MTProto.Telegram.UpdateStateStore do
  @moduledoc """
  Behaviour for loading and saving durable Telegram updates state.
  """

  alias MTProto.Telegram.UpdateState

  @callback load(key :: term()) ::
              {:ok, UpdateState.t() | nil} | {:error, term()}

  @callback save(key :: term(), update_state :: UpdateState.t()) ::
              :ok | {:error, term()}

  @callback delete(key :: term()) :: :ok | {:error, term()}
end
