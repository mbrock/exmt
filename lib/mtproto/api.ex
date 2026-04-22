defmodule MTProto.API do
  @moduledoc """
  Small hand-written Telegram API request wrappers.

  We intentionally keep this layer tiny and explicit instead of generating the
  entire Telegram API surface. These helpers only build the outer request
  envelopes we need right now.
  """

  alias MTProto.TL

  @invoke_with_layer 0xDA9B0D0D
  @init_connection 0xC1CD5EA9
  @help_get_config 0xC4F9186B

  @default_layer 214
  @default_device_model "exmt"
  @default_system_lang_code "en"
  @default_lang_pack ""
  @default_lang_code "en"

  @spec current_layer() :: integer()
  def current_layer, do: @default_layer

  @spec help_get_config() :: binary()
  def help_get_config, do: <<@help_get_config::little-unsigned-32>>

  @spec wrap_request(binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def wrap_request(query, opts \\ []) do
    with {:ok, initialized_query} <- init_connection(query, opts),
         {:ok, wrapped_query} <- invoke_with_layer(initialized_query, opts) do
      {:ok, wrapped_query}
    end
  end

  @spec invoke_with_layer(binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def invoke_with_layer(query, opts \\ []) do
    with {:ok, query} <- validate_query(query),
         {:ok, layer} <- fetch_integer_opt(opts, :layer, @default_layer) do
      {:ok,
       <<@invoke_with_layer::little-unsigned-32, TL.encode_int(layer)::binary,
         query::binary>>}
    end
  end

  @spec init_connection(binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def init_connection(query, opts \\ []) do
    with {:ok, query} <- validate_query(query),
         {:ok, api_id} <- fetch_integer_opt(opts, :api_id),
         {:ok, device_model} <-
           fetch_binary_opt(opts, :device_model, @default_device_model),
         {:ok, system_version} <-
           fetch_binary_opt(opts, :system_version, default_system_version()),
         {:ok, app_version} <-
           fetch_binary_opt(opts, :app_version, default_app_version()),
         {:ok, system_lang_code} <-
           fetch_binary_opt(
             opts,
             :system_lang_code,
             @default_system_lang_code
           ),
         {:ok, lang_pack} <-
           fetch_binary_opt(opts, :lang_pack, @default_lang_pack),
         {:ok, lang_code} <-
           fetch_binary_opt(opts, :lang_code, @default_lang_code) do
      flags = 0

      {:ok,
       <<@init_connection::little-unsigned-32, TL.encode_int(flags)::binary,
         TL.encode_int(api_id)::binary, TL.encode_bytes(device_model)::binary,
         TL.encode_bytes(system_version)::binary,
         TL.encode_bytes(app_version)::binary,
         TL.encode_bytes(system_lang_code)::binary,
         TL.encode_bytes(lang_pack)::binary,
         TL.encode_bytes(lang_code)::binary, query::binary>>}
    end
  end

  defp validate_query(query) when is_binary(query), do: {:ok, query}
  defp validate_query(_query), do: {:error, :invalid_query}

  defp fetch_integer_opt(opts, key, default \\ :missing) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error when default != :missing -> {:ok, default}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_binary_opt(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error when is_binary(default) -> {:ok, default}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp default_system_version do
    "OTP " <> System.otp_release()
  end

  defp default_app_version do
    :exmt
    |> Application.spec(:vsn)
    |> case do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
