defmodule MTProto.Telegram.API do
  @moduledoc """
  Small hand-written Telegram API request wrappers.

  This layer is intentionally separate from the MTProto transport/session
  client. It knows about Telegram API envelopes and a very small set of
  Telegram methods we currently care about.
  """

  alias MTProto.TL
  alias MTProto.Telegram.Request

  @invoke_with_layer 0xDA9B0D0D
  @init_connection 0xC1CD5EA9
  @help_get_config 0xC4F9186B
  @code_settings 0xAD253D78
  @auth_send_code 0xA677244F
  @auth_sign_in 0x8D52A951
  @input_user_self 0xF7C1B13F
  @users_get_full_user 0xB60F5918
  @updates_get_state 0xEDD4882A
  @updates_get_difference 0x19C2F763
  @help_get_nearest_dc 0x1FB33026
  @contacts_get_contacts 0x5DD69E12
  @messages_get_dialogs 0xA0F4CB4F
  @messages_get_history 0x4423E6C5
  @messages_send_message 0x545CD15A
  @input_peer_empty 0x7F3B18EA
  @input_peer_self 0x7DA07EC9
  @input_peer_chat 0x35A95CB9
  @input_peer_user 0xDDE8A54C
  @input_peer_channel 0x27BCBBFC

  @default_layer 214
  @default_device_model "exmt"
  @default_system_lang_code "en"
  @default_lang_pack ""
  @default_lang_code "en"

  @spec current_layer() :: integer()
  def current_layer, do: @default_layer

  @spec help_get_config(keyword()) :: Request.t()
  def help_get_config(_opts \\ []) do
    request(
      <<@help_get_config::little-unsigned-32>>,
      :help_get_config,
      "Config"
    )
  end

  @spec users_get_self(keyword()) :: Request.t()
  def users_get_self(_opts \\ []) do
    request(
      <<@users_get_full_user::little-unsigned-32, input_user_self()::binary>>,
      :users_get_self,
      "users.UserFull"
    )
  end

  @spec updates_get_state(keyword()) :: Request.t()
  def updates_get_state(_opts \\ []) do
    request(
      <<@updates_get_state::little-unsigned-32>>,
      :updates_get_state,
      "updates.State"
    )
  end

  @spec help_get_nearest_dc(keyword()) :: Request.t()
  def help_get_nearest_dc(_opts \\ []) do
    request(
      <<@help_get_nearest_dc::little-unsigned-32>>,
      :help_get_nearest_dc,
      "NearestDc"
    )
  end

  @spec contacts_get_contacts(keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def contacts_get_contacts(opts \\ []) when is_list(opts) do
    with {:ok, hash} <- fetch_long_opt(opts, :hash, 0) do
      {:ok,
       request(
         <<@contacts_get_contacts::little-unsigned-32,
           TL.encode_long(hash)::binary>>,
         :contacts_get_contacts,
         "contacts.Contacts"
       )}
    end
  end

  @spec messages_get_dialogs(keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def messages_get_dialogs(opts \\ []) when is_list(opts) do
    with {:ok, exclude_pinned} <-
           fetch_boolean_opt(opts, :exclude_pinned, false),
         {:ok, folder_id} <- fetch_optional_integer_opt(opts, :folder_id),
         {:ok, offset_date} <- fetch_integer_opt(opts, :offset_date, 0),
         {:ok, offset_id} <- fetch_integer_opt(opts, :offset_id, 0),
         {:ok, offset_peer} <-
           fetch_input_peer_opt(opts, :offset_peer, :empty),
         {:ok, limit} <- fetch_integer_opt(opts, :limit, 20),
         {:ok, hash} <- fetch_long_opt(opts, :hash, 0) do
      flags =
        0
        |> put_flag(0, exclude_pinned)
        |> put_flag(1, not is_nil(folder_id))

      {:ok,
       request(
         [
           <<@messages_get_dialogs::little-unsigned-32>>,
           TL.encode_int(flags),
           maybe_encode_int(folder_id),
           TL.encode_int(offset_date),
           TL.encode_int(offset_id),
           offset_peer,
           TL.encode_int(limit),
           TL.encode_long(hash)
         ]
         |> IO.iodata_to_binary(),
         :messages_get_dialogs,
         "messages.Dialogs"
       )}
    end
  end

  @spec messages_get_history(keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def messages_get_history(opts) when is_list(opts) do
    with {:ok, peer} <- fetch_input_peer_opt(opts, :peer, :self),
         {:ok, offset_id} <- fetch_integer_opt(opts, :offset_id, 0),
         {:ok, offset_date} <- fetch_integer_opt(opts, :offset_date, 0),
         {:ok, add_offset} <- fetch_integer_opt(opts, :add_offset, 0),
         {:ok, limit} <- fetch_integer_opt(opts, :limit, 20),
         {:ok, max_id} <- fetch_integer_opt(opts, :max_id, 0),
         {:ok, min_id} <- fetch_integer_opt(opts, :min_id, 0),
         {:ok, hash} <- fetch_long_opt(opts, :hash, 0) do
      {:ok,
       request(
         [
           <<@messages_get_history::little-unsigned-32>>,
           peer,
           TL.encode_int(offset_id),
           TL.encode_int(offset_date),
           TL.encode_int(add_offset),
           TL.encode_int(limit),
           TL.encode_int(max_id),
           TL.encode_int(min_id),
           TL.encode_long(hash)
         ]
         |> IO.iodata_to_binary(),
         :messages_get_history,
         "messages.Messages"
       )}
    end
  end

  @spec messages_send_message(binary(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def messages_send_message(message, opts \\ [])
      when is_binary(message) and is_list(opts) do
    with {:ok, peer} <- fetch_input_peer_opt(opts, :peer, :self),
         {:ok, random_id} <- fetch_signed_long_opt(opts, :random_id),
         {:ok, no_webpage} <- fetch_boolean_opt(opts, :no_webpage, false),
         {:ok, silent} <- fetch_boolean_opt(opts, :silent, false),
         {:ok, clear_draft} <- fetch_boolean_opt(opts, :clear_draft, false) do
      flags =
        0
        |> put_flag(1, no_webpage)
        |> put_flag(5, silent)
        |> put_flag(7, clear_draft)

      {:ok,
       request(
         [
           <<@messages_send_message::little-unsigned-32>>,
           TL.encode_int(flags),
           peer,
           TL.encode_bytes(message),
           TL.encode_signed_long(random_id)
         ]
         |> IO.iodata_to_binary(),
         :messages_send_message,
         "Updates"
       )}
    end
  end

  @spec updates_get_difference(MTProto.Telegram.UpdateState.t() | keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def updates_get_difference(%MTProto.Telegram.UpdateState{} = state) do
    state
    |> MTProto.Telegram.UpdateState.to_difference_opts()
    |> updates_get_difference()
  end

  def updates_get_difference(opts) when is_list(opts) do
    with {:ok, pts} <- fetch_integer_opt(opts, :pts),
         {:ok, pts_limit} <- fetch_optional_integer_opt(opts, :pts_limit),
         {:ok, pts_total_limit} <-
           fetch_optional_integer_opt(opts, :pts_total_limit),
         {:ok, date} <- fetch_integer_opt(opts, :date),
         {:ok, qts} <- fetch_integer_opt(opts, :qts),
         {:ok, qts_limit} <- fetch_optional_integer_opt(opts, :qts_limit) do
      flags =
        0
        |> put_flag(0, not is_nil(pts_total_limit))
        |> put_flag(1, not is_nil(pts_limit))
        |> put_flag(2, not is_nil(qts_limit))

      {:ok,
       request(
         [
           <<@updates_get_difference::little-unsigned-32>>,
           TL.encode_int(flags),
           TL.encode_int(pts),
           maybe_encode_int(pts_limit),
           maybe_encode_int(pts_total_limit),
           TL.encode_int(date),
           TL.encode_int(qts),
           maybe_encode_int(qts_limit)
         ]
         |> IO.iodata_to_binary(),
         :updates_get_difference,
         "updates.Difference"
       )}
    end
  end

  @spec code_settings(keyword()) :: {:ok, binary()} | {:error, term()}
  def code_settings(opts \\ []) when is_list(opts) do
    with {:ok, allow_flashcall} <-
           fetch_boolean_opt(opts, :allow_flashcall, false),
         {:ok, current_number} <-
           fetch_boolean_opt(opts, :current_number, false),
         {:ok, allow_app_hash} <-
           fetch_boolean_opt(opts, :allow_app_hash, false),
         {:ok, allow_missed_call} <-
           fetch_boolean_opt(opts, :allow_missed_call, false),
         {:ok, allow_firebase} <-
           fetch_boolean_opt(opts, :allow_firebase, false),
         {:ok, unknown_number} <-
           fetch_boolean_opt(opts, :unknown_number, false),
         {:ok, logout_tokens} <-
           fetch_optional_binary_list_opt(opts, :logout_tokens),
         {:ok, token} <- fetch_optional_binary_opt(opts, :token),
         {:ok, app_sandbox} <-
           fetch_optional_boolean_opt(opts, :app_sandbox),
         :ok <- validate_code_settings_token(token, app_sandbox) do
      flags =
        0
        |> put_flag(0, allow_flashcall)
        |> put_flag(1, current_number)
        |> put_flag(4, allow_app_hash)
        |> put_flag(5, allow_missed_call)
        |> put_flag(6, not is_nil(logout_tokens))
        |> put_flag(7, allow_firebase)
        |> put_flag(8, not is_nil(token))
        |> put_flag(9, unknown_number)

      encoded =
        [
          <<@code_settings::little-unsigned-32>>,
          TL.encode_int(flags),
          maybe_encode_logout_tokens(logout_tokens),
          maybe_encode_token(token, app_sandbox)
        ]
        |> IO.iodata_to_binary()

      {:ok, encoded}
    end
  end

  @spec auth_send_code(binary(), binary(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def auth_send_code(phone_number, api_hash, opts \\ []) do
    with {:ok, phone_number} <-
           validate_binary_arg(phone_number, :phone_number),
         {:ok, api_id} <- fetch_integer_opt(opts, :api_id),
         {:ok, api_hash} <- validate_binary_arg(api_hash, :api_hash),
         {:ok, settings} <- code_settings(Keyword.get(opts, :settings, [])) do
      {:ok,
       request(
         <<@auth_send_code::little-unsigned-32,
           TL.encode_bytes(phone_number)::binary,
           TL.encode_int(api_id)::binary, TL.encode_bytes(api_hash)::binary,
           settings::binary>>,
         :auth_send_code,
         "auth.SentCode"
       )}
    end
  end

  @spec auth_sign_in(binary(), binary(), binary(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def auth_sign_in(phone_number, phone_code_hash, phone_code, opts \\ []) do
    with {:ok, phone_number} <-
           validate_binary_arg(phone_number, :phone_number),
         {:ok, phone_code_hash} <-
           validate_binary_arg(phone_code_hash, :phone_code_hash),
         {:ok, phone_code} <- validate_binary_arg(phone_code, :phone_code),
         :ok <- validate_unsupported_opt(opts, :email_verification) do
      flags = 1

      {:ok,
       request(
         <<@auth_sign_in::little-unsigned-32, TL.encode_int(flags)::binary,
           TL.encode_bytes(phone_number)::binary,
           TL.encode_bytes(phone_code_hash)::binary,
           TL.encode_bytes(phone_code)::binary>>,
         :auth_sign_in,
         "auth.Authorization"
       )}
    end
  end

  @spec wrap_request(Request.t() | binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def wrap_request(query_or_request, opts \\ [])

  def wrap_request(%Request{query: query}, opts) do
    wrap_request(query, opts)
  end

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

  defp request(query, request, result_type) when is_binary(query) do
    Request.new(query, request, result_type)
  end

  defp input_user_self, do: <<@input_user_self::little-unsigned-32>>
  defp input_peer_empty, do: <<@input_peer_empty::little-unsigned-32>>
  defp input_peer_self, do: <<@input_peer_self::little-unsigned-32>>

  defp input_peer_chat(chat_id) when is_integer(chat_id) do
    <<@input_peer_chat::little-unsigned-32, TL.encode_long(chat_id)::binary>>
  end

  defp input_peer_user(user_id, access_hash)
       when is_integer(user_id) and is_integer(access_hash) do
    <<@input_peer_user::little-unsigned-32, TL.encode_long(user_id)::binary,
      TL.encode_long(access_hash)::binary>>
  end

  defp input_peer_channel(channel_id, access_hash)
       when is_integer(channel_id) and is_integer(access_hash) do
    <<@input_peer_channel::little-unsigned-32,
      TL.encode_long(channel_id)::binary,
      TL.encode_long(access_hash)::binary>>
  end

  defp fetch_integer_opt(opts, key, default \\ :missing) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error when default != :missing -> {:ok, default}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_long_opt(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value}
      when is_integer(value) and value >= 0 and value <= 0xFFFF_FFFF_FFFF_FFFF ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_option, key}}

      :error when default != :missing ->
        {:ok, default}

      :error ->
        {:error, {:missing_option, key}}
    end
  end

  defp fetch_signed_long_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value}
      when is_integer(value) and value >= -0x8000_0000_0000_0000 and
             value <= 0x7FFF_FFFF_FFFF_FFFF ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_option, key}}

      :error ->
        {:error, {:missing_option, key}}
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

  defp fetch_boolean_opt(opts, key, default) when is_boolean(default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp fetch_optional_integer_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_optional_binary_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_optional_boolean_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_optional_binary_list_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          {:ok, values}
        else
          {:error, {:invalid_option, key}}
        end

      {:ok, nil} ->
        {:ok, nil}

      {:ok, _value} ->
        {:error, {:invalid_option, key}}

      :error ->
        {:ok, nil}
    end
  end

  defp fetch_input_peer_opt(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        normalize_input_peer(value, key)

      :error ->
        normalize_input_peer(default, key)
    end
  end

  defp normalize_input_peer(:empty, _key), do: {:ok, input_peer_empty()}
  defp normalize_input_peer(:self, _key), do: {:ok, input_peer_self()}

  defp normalize_input_peer({:chat, chat_id}, _key) when is_integer(chat_id),
    do: {:ok, input_peer_chat(chat_id)}

  defp normalize_input_peer({:user, user_id, access_hash}, _key)
       when is_integer(user_id) and is_integer(access_hash),
       do: {:ok, input_peer_user(user_id, access_hash)}

  defp normalize_input_peer({:channel, channel_id, access_hash}, _key)
       when is_integer(channel_id) and is_integer(access_hash),
       do: {:ok, input_peer_channel(channel_id, access_hash)}

  defp normalize_input_peer(_value, key), do: {:error, {:invalid_option, key}}

  defp validate_binary_arg(value, _name) when is_binary(value),
    do: {:ok, value}

  defp validate_binary_arg(_value, name),
    do: {:error, {:invalid_argument, name}}

  defp validate_code_settings_token(nil, nil), do: :ok

  defp validate_code_settings_token(nil, _app_sandbox),
    do: {:error, {:invalid_option, :token}}

  defp validate_code_settings_token(_token, _app_sandbox), do: :ok

  defp validate_unsupported_opt(opts, key) do
    case Keyword.has_key?(opts, key) do
      true -> {:error, {:unsupported_option, key}}
      false -> :ok
    end
  end

  defp maybe_encode_logout_tokens(nil), do: []

  defp maybe_encode_logout_tokens(logout_tokens) do
    TL.encode_vector(logout_tokens, &TL.encode_bytes/1)
  end

  defp maybe_encode_token(nil, _app_sandbox), do: []

  defp maybe_encode_token(token, app_sandbox) do
    [TL.encode_bytes(token), TL.encode_bool(app_sandbox || false)]
  end

  defp maybe_encode_int(nil), do: []

  defp maybe_encode_int(value) when is_integer(value),
    do: TL.encode_int(value)

  defp put_flag(flags, _bit, false), do: flags
  defp put_flag(flags, bit, true), do: Bitwise.bor(flags, Bitwise.bsl(1, bit))

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
