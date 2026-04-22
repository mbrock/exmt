defmodule MTProto.SessionStore do
  @moduledoc """
  Behaviour for loading and saving durable MTProto session data.

  The library core stays agnostic about where session material lives. A store
  may persist to disk, a database, or keep the data in memory.
  """

  alias MTProto.SessionData

  @callback load(key :: term()) ::
              {:ok, SessionData.t() | nil} | {:error, term()}

  @callback save(key :: term(), session_data :: SessionData.t()) ::
              :ok | {:error, term()}

  @callback delete(key :: term()) :: :ok | {:error, term()}
end
