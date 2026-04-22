defmodule MTProto.API.Result do
  @moduledoc """
  Schema-driven decoding helpers for raw Telegram API results.
  """

  alias MTProto.TL.Runtime
  alias MTProto.TL.Runtime.Decoded

  @spec decode(binary(), keyword()) ::
          {:ok, Runtime.decoded_value()} | {:error, term()}
  def decode(binary, opts \\ []) when is_binary(binary) do
    {expected_type, runtime_opts} = Keyword.pop(opts, :type)

    with {:ok, decoded, <<>>} <- Runtime.decode(binary, runtime_opts),
         {:ok, decoded} <-
           unwrap(decoded, Keyword.put(runtime_opts, :type, expected_type)),
         :ok <- validate_expected_type(decoded, expected_type) do
      {:ok, decoded}
    else
      {:ok, _decoded, rest} -> {:error, {:trailing_bytes, byte_size(rest)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rpc_error?(term()) :: boolean()
  def rpc_error?(%Decoded{type_name: "RpcError"}), do: true
  def rpc_error?(_decoded), do: false

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

  defp validate_expected_type(_decoded, nil), do: :ok

  defp validate_expected_type(
         %Decoded{type_name: "RpcError"},
         _expected_type
       ),
       do: :ok

  defp validate_expected_type(
         %Decoded{tl_name: "gzip_packed", fields: %{unpacked: unpacked}},
         expected_type
       ) do
    validate_expected_type(unpacked, expected_type)
  end

  defp validate_expected_type(
         %Decoded{type_name: expected_type},
         expected_type
       ),
       do: :ok

  defp validate_expected_type(
         %Decoded{constructor_id: constructor_id, type_name: actual_type},
         expected_type
       ) do
    {:error,
     {:unexpected_result_type, constructor_id, actual_type, expected_type}}
  end

  defp validate_expected_type(actual_value, expected_type) do
    {:error, {:unexpected_result_value, actual_value, expected_type}}
  end

  defp gunzip(binary) do
    {:ok, :zlib.gunzip(binary)}
  rescue
    error -> {:error, {:gzip_error, error}}
  end
end
