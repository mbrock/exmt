defmodule MTProto.SessionStore.File do
  @moduledoc """
  File-backed `MTProto.SessionStore` implementation.

  Session data is stored as an Erlang term containing the serializable map form
  of `MTProto.SessionData`.
  """

  @behaviour MTProto.SessionStore

  alias MTProto.SessionData

  @impl true
  def load(key) do
    with {:ok, path} <- path_for(key) do
      case File.read(path) do
        {:ok, binary} ->
          with {:ok, term} <- binary_to_term(binary),
               {:ok, session_data} <- SessionData.from_map(term) do
            {:ok, session_data}
          end

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def save(key, %SessionData{} = session_data) do
    with {:ok, path} <- path_for(key),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp_path =
        path <>
          ".tmp-" <>
          Integer.to_string(System.unique_integer([:positive, :monotonic]))

      binary =
        session_data
        |> SessionData.to_map()
        |> :erlang.term_to_binary(compressed: 9)

      with :ok <- File.write(tmp_path, binary, [:binary]),
           :ok <- File.chmod(tmp_path, 0o600),
           :ok <- File.rename(tmp_path, path) do
        :ok
      else
        {:error, _reason} = error ->
          File.rm(tmp_path)
          error
      end
    end
  end

  def save(_key, _session_data), do: {:error, :invalid_session_data}

  @impl true
  def delete(key) do
    with {:ok, path} <- path_for(key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp path_for(path) when is_binary(path) and path != "", do: {:ok, path}

  defp path_for(opts) when is_list(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      {:ok, _path} -> {:error, :invalid_path}
      :error -> {:error, :missing_path}
    end
  end

  defp path_for(_key), do: {:error, :invalid_path}

  defp binary_to_term(binary) when is_binary(binary) do
    Code.ensure_loaded(SessionData)
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_session_store_data}
  end
end
