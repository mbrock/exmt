defmodule MTProto.SessionData do
  @moduledoc """
  Durable MTProto session material.

  This struct is intentionally limited to the data worth persisting between
  process lifetimes. It excludes transient connection/session runtime state such
  as `session_id`, pending requests, and sequence counters.
  """

  alias MTProto.Auth.ExchangeResult
  alias MTProto.{AuthKey, Session}

  @version 1

  @enforce_keys [:auth_key_data, :server_salt, :time_offset, :dc_id]
  defstruct [:auth_key_data, :server_salt, :time_offset, :dc_id]

  @type t :: %__MODULE__{
          auth_key_data: binary(),
          server_salt: integer(),
          time_offset: integer(),
          dc_id: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, auth_key_data} <- fetch_auth_key_data(opts),
         {:ok, server_salt} <- fetch_integer_opt(opts, :server_salt),
         {:ok, time_offset} <- fetch_integer_opt(opts, :time_offset, 0),
         {:ok, dc_id} <- fetch_integer_opt(opts, :dc_id),
         :ok <- validate_signed_64(server_salt, :invalid_server_salt),
         :ok <- validate_dc_id(dc_id) do
      {:ok,
       %__MODULE__{
         auth_key_data: auth_key_data,
         server_salt: server_salt,
         time_offset: time_offset,
         dc_id: dc_id
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, session_data} ->
        session_data

      {:error, reason} ->
        raise ArgumentError, "invalid session data: #{inspect(reason)}"
    end
  end

  @spec from_exchange_result(ExchangeResult.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_exchange_result(%ExchangeResult{} = result, opts)
      when is_list(opts) do
    new(
      Keyword.merge(
        [
          auth_key_data: result.auth_key.data,
          server_salt: result.server_salt,
          time_offset: result.time_offset
        ],
        opts
      )
    )
  end

  @spec from_session(Session.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_session(%Session{} = session, opts) when is_list(opts) do
    new(
      Keyword.merge(
        [
          auth_key_data: session.auth_key.data,
          server_salt: session.server_salt,
          time_offset: session.time_offset
        ],
        opts
      )
    )
  end

  @spec auth_key(t()) :: AuthKey.t()
  def auth_key(%__MODULE__{auth_key_data: auth_key_data}) do
    AuthKey.new!(auth_key_data)
  end

  @spec to_session_opts(t(), keyword()) :: keyword()
  def to_session_opts(%__MODULE__{} = session_data, opts \\ []) do
    Keyword.merge(
      [
        auth_key: auth_key(session_data),
        server_salt: session_data.server_salt,
        time_offset: session_data.time_offset
      ],
      opts
    )
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session_data) do
    %{
      version: @version,
      auth_key_data: session_data.auth_key_data,
      server_salt: session_data.server_salt,
      time_offset: session_data.time_offset,
      dc_id: session_data.dc_id
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, version} <- fetch_map_value(map, :version, @version),
         :ok <- validate_version(version),
         {:ok, auth_key_data} <- fetch_map_value(map, :auth_key_data),
         {:ok, server_salt} <- fetch_map_value(map, :server_salt),
         {:ok, time_offset} <- fetch_map_value(map, :time_offset, 0),
         {:ok, dc_id} <- fetch_map_value(map, :dc_id) do
      new(
        auth_key_data: auth_key_data,
        server_salt: server_salt,
        time_offset: time_offset,
        dc_id: dc_id
      )
    end
  end

  def from_map(_map), do: {:error, :invalid_session_data_map}

  defp fetch_auth_key_data(opts) do
    case Keyword.fetch(opts, :auth_key_data) do
      {:ok, auth_key_data} when is_binary(auth_key_data) ->
        case AuthKey.new(auth_key_data) do
          {:ok, _auth_key} -> {:ok, auth_key_data}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _auth_key_data} ->
        {:error, :invalid_auth_key}

      :error ->
        {:error, :missing_auth_key}
    end
  end

  defp fetch_integer_opt(opts, key, default \\ :no_default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error when default != :no_default -> {:ok, default}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_map_value(map, key, default \\ :no_default) do
    string_key = Atom.to_string(key)

    case map do
      %{^key => value} ->
        {:ok, value}

      %{^string_key => value} ->
        {:ok, value}

      _ when default != :no_default ->
        {:ok, default}

      _ ->
        {:error, {:missing_key, key}}
    end
  end

  defp validate_version(@version), do: :ok

  defp validate_version(_version),
    do: {:error, :unsupported_session_data_version}

  defp validate_dc_id(dc_id) when is_integer(dc_id) and dc_id >= 0, do: :ok
  defp validate_dc_id(_dc_id), do: {:error, :invalid_dc_id}

  defp validate_signed_64(value, _error)
       when is_integer(value) and value >= -0x8000_0000_0000_0000 and
              value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: :ok

  defp validate_signed_64(_value, error), do: {:error, error}
end
