defmodule MTProto.Telegram.API do
  @moduledoc """
  Schema-driven Telegram API request compilation and envelope helpers.
  """

  use MTProto.Telegram.API.Namespaces

  alias MTProto.TL.Encoder
  alias MTProto.TL.Schema.Registry, as: SchemaRegistry
  alias MTProto.Telegram.Request

  @default_layer 214
  @default_device_model "exmt"
  @default_system_lang_code "en"
  @default_lang_pack ""
  @default_lang_code "en"
  @telegram_schema :telegram_api

  @type requestish :: Request.t() | {binary(), keyword()}

  @spec current_layer() :: integer()
  def current_layer, do: @default_layer

  @spec compile_request(requestish(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def compile_request(request, opts \\ [])

  def compile_request(%Request{} = request, _opts), do: {:ok, request}

  def compile_request({method, params}, opts)
      when is_binary(method) and is_list(params) and is_list(opts) do
    with {:ok, definition} <-
           SchemaRegistry.function(@telegram_schema, method),
         {:ok, query} <-
           Encoder.encode_definition(
             definition,
             Keyword.merge(opts, params),
             encoder_opts()
           ) do
      {:ok,
       Request.new(
         query,
         request_name(method),
         SchemaRegistry.result_type_name(definition)
       )}
    else
      :error -> {:error, {:unknown_telegram_method, method}}
      {:error, reason} -> {:error, reason}
    end
  end

  def compile_request(_request, _opts), do: {:error, :invalid_request}

  @spec wrap_request(requestish() | binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def wrap_request(query_or_request, opts \\ [])

  def wrap_request({method, params}, opts)
      when is_binary(method) and is_list(params) do
    with {:ok, request} <- compile_request({method, params}, opts) do
      wrap_request(request, opts)
    end
  end

  def wrap_request(%Request{query: query}, opts),
    do: wrap_request(query, opts)

  def wrap_request(query, opts) do
    with {:ok, initialized_query} <- init_connection(query, opts),
         {:ok, wrapped_query} <- invoke_with_layer(initialized_query, opts) do
      {:ok, wrapped_query}
    end
  end

  @spec invoke_with_layer(binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def invoke_with_layer(query, opts \\ []) do
    with {:ok, query} <- validate_query(query),
         {:ok, %Request{query: wrapped_query}} <-
           compile_request(
             {"invokeWithLayer",
              [layer: Keyword.get(opts, :layer, @default_layer), query: query]}
           ) do
      {:ok, wrapped_query}
    end
  end

  @spec init_connection(binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def init_connection(query, opts \\ []) do
    with {:ok, query} <- validate_query(query),
         {:ok, %Request{query: initialized_query}} <-
           compile_request(
             {"initConnection", [query: query]},
             init_connection_opts(opts)
           ) do
      {:ok, initialized_query}
    end
  end

  defp init_connection_opts(opts) do
    opts
    |> Keyword.put_new(:device_model, @default_device_model)
    |> Keyword.put_new(:system_version, default_system_version())
    |> Keyword.put_new(:app_version, default_app_version())
    |> Keyword.put_new(:system_lang_code, @default_system_lang_code)
    |> Keyword.put_new(:lang_pack, @default_lang_pack)
    |> Keyword.put_new(:lang_code, @default_lang_code)
  end

  defp request_name(method) do
    method
    |> String.replace(".", "_")
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp encoder_opts do
    [schema: @telegram_schema, normalize_value: &normalize_telegram_value/2]
  end

  defp validate_query(query) when is_binary(query), do: {:ok, query}
  defp validate_query(_query), do: {:error, :invalid_query}

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

  defp normalize_telegram_value("InputPeer", :empty),
    do: {"inputPeerEmpty", []}

  defp normalize_telegram_value("InputPeer", :self),
    do: {"inputPeerSelf", []}

  defp normalize_telegram_value("InputPeer", {:chat, chat_id})
       when is_integer(chat_id),
       do: {"inputPeerChat", [chat_id: chat_id]}

  defp normalize_telegram_value("InputPeer", {:user, user_id, access_hash})
       when is_integer(user_id) and is_integer(access_hash),
       do: {"inputPeerUser", [user_id: user_id, access_hash: access_hash]}

  defp normalize_telegram_value(
         "InputPeer",
         {:channel, channel_id, access_hash}
       )
       when is_integer(channel_id) and is_integer(access_hash),
       do:
         {"inputPeerChannel",
          [channel_id: channel_id, access_hash: access_hash]}

  defp normalize_telegram_value("InputUser", :self),
    do: {"inputUserSelf", []}

  defp normalize_telegram_value(_type_name, value), do: value
end
