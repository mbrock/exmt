defmodule MTProto.API.Result do
  @moduledoc """
  Schema-driven decoding helpers for raw Telegram API results.
  """

  alias MTProto.TL.Runtime
  alias MTProto.TL.Runtime.Decoded

  @spec decode(binary(), keyword()) ::
          {:ok, Runtime.decoded_value()} | {:error, term()}
  def decode(binary, opts \\ []) when is_binary(binary) do
    with {:ok, decoded, <<>>} <- Runtime.decode(binary, opts) do
      unwrap(decoded, opts)
    else
      {:ok, _decoded, rest} -> {:error, {:trailing_bytes, byte_size(rest)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap(
         %Decoded{tl_name: "gzip_packed", fields: %{packed_data: packed_data}} =
           decoded,
         opts
       ) do
    with {:ok, unpacked_data} <- gunzip(packed_data),
         {:ok, unpacked} <- decode(unpacked_data, opts) do
      {:ok,
       %Decoded{
         decoded
         | fields:
             decoded.fields
             |> Map.put(:unpacked_data, unpacked_data)
             |> Map.put(:unpacked, unpacked)
       }}
    end
  end

  defp unwrap(decoded, _opts), do: {:ok, decoded}

  defp gunzip(binary) do
    {:ok, :zlib.gunzip(binary)}
  rescue
    error -> {:error, {:gzip_error, error}}
  end
end
