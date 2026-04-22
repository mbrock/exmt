defmodule MTProto.Telegram.RPCError do
  @moduledoc """
  Structured Telegram RPC error decoded from `rpc_error`.
  """

  alias MTProto.TL.Runtime.Decoded

  @enforce_keys [:code, :message]
  defexception [
    :code,
    :message,
    :name,
    :value,
    :migrate_to_dc,
    :wait_seconds
  ]

  @type t :: %__MODULE__{
          code: integer(),
          message: binary(),
          name: binary() | nil,
          value: integer() | nil,
          migrate_to_dc: integer() | nil,
          wait_seconds: integer() | nil
        }

  @spec from_decoded(term()) :: {:ok, t()} | :error
  def from_decoded(%Decoded{
        tl_name: "gzip_packed",
        fields: %{unpacked: unpacked}
      }) do
    from_decoded(unpacked)
  end

  def from_decoded(%Decoded{
        tl_name: "rpc_error",
        fields: %{error_code: error_code, error_message: error_message}
      })
      when is_integer(error_code) and is_binary(error_message) do
    {name, value} = split_error_message(error_message)

    {:ok,
     exception(
       code: error_code,
       message: error_message,
       name: name,
       value: value,
       migrate_to_dc: migrate_to_dc(name, value),
       wait_seconds: wait_seconds(name, value)
     )}
  end

  def from_decoded(_decoded), do: :error

  @impl true
  def message(%__MODULE__{code: code, message: message}) do
    "#{message} (RPC #{code})"
  end

  defp split_error_message(message) do
    case Regex.run(~r/\A([A-Z0-9_]+?)(?:_(\d+))?\z/, message) do
      [_, name, value] -> {name, String.to_integer(value)}
      [_, name] -> {name, nil}
      _ -> {nil, nil}
    end
  end

  defp migrate_to_dc(name, value)
       when name in ["NETWORK_MIGRATE", "PHONE_MIGRATE", "USER_MIGRATE"] do
    value
  end

  defp migrate_to_dc(_name, _value), do: nil

  defp wait_seconds("FLOOD_WAIT", value), do: value
  defp wait_seconds(_name, _value), do: nil
end
