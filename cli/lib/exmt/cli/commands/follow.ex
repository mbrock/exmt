defmodule Exmt.CLI.Commands.Follow do
  @moduledoc false

  @behaviour Exmt.CLI.Command

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.{API, Client, UpdateState, Updates}
  alias MTProto.TL.Runtime.Decoded

  @default_ping_interval 30_000
  @default_poll_interval 2_000

  @impl true
  def command_path, do: ["follow"]

  @impl true
  def usage do
    """
    usage:
      exmt follow
      exmt follow --duration 60000 --poll-interval 1000
      exmt follow --session-file .exmt/session.term --timeout 60000 --verbose
    """
  end

  @impl true
  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    Telegram.run_command(fn ->
      with {:ok, opts} <- parse_args(argv),
           {:ok, context} <- Telegram.build_context(opts, require: [:api_id]),
           :ok <- Telegram.print_banner(context),
           {:ok, summary} <-
             Telegram.try_endpoints(context, &follow(&1, &2, context, opts)) do
        print_summary(summary)
        :ok
      else
        {:error, reason} ->
          IO.puts(:stderr, "error: #{Telegram.format_error(reason)}")
          IO.puts(:stderr, usage())
          {:error, reason}
      end
    end)
  end

  defp parse_args(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict:
          Telegram.common_switches() ++
            [
              duration: :integer,
              ping_interval: :integer,
              poll_interval: :integer
            ]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      rest != [] ->
        {:error, {:unexpected_arguments, rest}}

      true ->
        validate_opts(opts)
    end
  end

  defp validate_opts(opts) do
    with :ok <- validate_non_negative_integer_opt(opts, :duration),
         :ok <- validate_positive_integer_opt(opts, :ping_interval),
         :ok <- validate_positive_integer_opt(opts, :poll_interval) do
      {:ok, opts}
    end
  end

  defp follow(client, endpoint, context, opts) do
    with {:ok, session_id} <- Telegram.connect(client, context),
         {:ok, update_state, source} <-
           load_or_fetch_update_state(client, context),
         :ok <-
           print_follow_start(
             endpoint,
             session_id,
             context,
             update_state,
             source
           ),
         {:ok, final_state} <-
           follow_loop(client, context, new_loop_state(opts, update_state)) do
      {:ok,
       %{
         endpoint: endpoint,
         session_id: session_id,
         update_state: final_state
       }}
    end
  end

  defp load_or_fetch_update_state(client, context) do
    case Telegram.load_update_state(context) do
      {:ok, %UpdateState{} = update_state} ->
        {:ok, update_state, :stored}

      {:ok, nil} ->
        with {:ok, update_state} <- fetch_update_state(client, context) do
          {:ok, update_state, :fetched}
        end

      {:error, reason} ->
        {:error, {:update_state_store_load_failed, reason}}
    end
  end

  defp fetch_update_state(client, context) do
    with {:ok, decoded} <-
           Client.request_sync(
             client,
             API.updates_get_state(),
             Telegram.request_opts(context)
           ),
         {:ok, update_state} <- UpdateState.from_decoded(decoded),
         :ok <- persist_update_state(context, update_state) do
      {:ok, update_state}
    end
  end

  defp print_follow_start(
         endpoint,
         session_id,
         context,
         update_state,
         source
       ) do
    IO.puts("Connected on #{Telegram.format_endpoint(endpoint)}")
    IO.puts("Session id: #{session_id}")
    IO.puts("Updates file: #{Telegram.update_state_file(context)}")

    IO.puts(
      "Starting from #{source_label(source)} state #{format_update_state(update_state)}"
    )

    IO.puts("Polling updates.getDifference. Press Ctrl+C to stop.")
    :ok
  end

  defp source_label(:stored), do: "stored"
  defp source_label(:fetched), do: "fresh"

  defp new_loop_state(opts, update_state) do
    now = now_ms()
    ping_interval = ping_interval(opts)

    %{
      update_state: update_state,
      deadline: deadline(opts),
      poll_interval: poll_interval(opts),
      ping_interval: ping_interval,
      next_poll_at: now,
      next_ping_at: maybe_next_ping_at(now, ping_interval),
      next_ping_id: 1,
      verbose?: Keyword.get(opts, :verbose, false)
    }
  end

  defp follow_loop(client, context, loop_state) do
    receive do
      {:mtproto, ^client, event} ->
        maybe_print_async_event(:mtproto, event, loop_state)
        follow_loop(client, context, loop_state)

      {:telegram, ^client, event} ->
        maybe_print_async_event(:telegram, event, loop_state)
        follow_loop(client, context, loop_state)

      {:EXIT, ^client, reason} ->
        {:error, {:connection_exit, reason}}
    after
      next_timeout(loop_state) ->
        step_follow_loop(client, context, loop_state)
    end
  end

  defp step_follow_loop(
         client,
         context,
         %{deadline: deadline, update_state: update_state} = loop_state
       ) do
    now = now_ms()

    cond do
      is_integer(deadline) and now >= deadline ->
        {:ok, update_state}

      due?(loop_state.next_poll_at, now) ->
        poll_difference(client, context, loop_state)

      due?(loop_state.next_ping_at, now) ->
        send_ping(client, context, loop_state)

      true ->
        follow_loop(client, context, loop_state)
    end
  end

  defp poll_difference(client, context, loop_state) do
    with {:ok, request} <- API.updates_get_difference(loop_state.update_state),
         {:ok, decoded} <-
           Client.request_sync(
             client,
             request,
             Telegram.request_opts(context)
           ),
         {:ok, next_loop_state} <-
           apply_difference(client, context, loop_state, decoded) do
      follow_loop(client, context, next_loop_state)
    end
  end

  defp apply_difference(client, context, loop_state, decoded) do
    case Updates.apply_difference(loop_state.update_state, decoded) do
      {:ok, difference} ->
        print_difference_items(difference.items, difference.context)

        with {:ok, update_state} <-
               maybe_persist_update_state(
                 context,
                 loop_state.update_state,
                 difference.state
               ) do
          {:ok,
           %{
             loop_state
             | update_state: update_state,
               next_poll_at:
                 next_poll_at(loop_state.poll_interval, difference.final?)
           }}
        end

      {:reset, _stale_state} ->
        IO.puts("[#{timestamp()}] updates.differenceTooLong; resetting state")

        with {:ok, update_state} <- fetch_update_state(client, context) do
          {:ok,
           %{
             loop_state
             | update_state: update_state,
               next_poll_at: next_poll_at(loop_state.poll_interval, false)
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_persist_update_state(_context, current, current) do
    {:ok, current}
  end

  defp maybe_persist_update_state(context, _current, next_state) do
    with :ok <- persist_update_state(context, next_state) do
      {:ok, next_state}
    end
  end

  defp persist_update_state(context, %UpdateState{} = update_state) do
    case Telegram.save_update_state(context, update_state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:update_state_store_save_failed, reason}}
    end
  end

  defp print_difference_items(items, context) do
    peer_index = build_peer_index(context)

    Enum.each(items, fn item ->
      IO.puts("[#{timestamp()}] #{format_item(item, peer_index)}")
    end)
  end

  defp format_item({:message, message}, peer_index) do
    "message " <> format_message(message, peer_index)
  end

  defp format_item({:encrypted_message, message}, _peer_index) do
    "encrypted_message " <> format_decoded_name(message)
  end

  defp format_item({:update, update}, peer_index) do
    format_update(update, peer_index)
  end

  defp format_update(
         %Decoded{tl_name: tl_name, fields: %{message: %Decoded{} = message}},
         peer_index
       ) do
    "#{tl_name} " <> format_message(message, peer_index)
  end

  defp format_update(%Decoded{tl_name: tl_name, fields: fields}, peer_index) do
    summary =
      fields
      |> summarize_update_fields(peer_index)
      |> Enum.join(" ")

    case summary do
      "" -> tl_name
      _ -> "#{tl_name} #{summary}"
    end
  end

  defp format_update(decoded, _peer_index), do: format_decoded_name(decoded)

  defp summarize_update_fields(fields, peer_index) do
    [
      maybe_field("peer", Map.get(fields, :peer), peer_index),
      maybe_field("peer", Map.get(fields, :peer_id), peer_index),
      maybe_integer_field("user_id", Map.get(fields, :user_id)),
      maybe_integer_field("chat_id", Map.get(fields, :chat_id)),
      maybe_integer_field("channel_id", Map.get(fields, :channel_id)),
      maybe_integer_field("pts", Map.get(fields, :pts)),
      maybe_integer_field("pts_count", Map.get(fields, :pts_count)),
      maybe_integer_field("qts", Map.get(fields, :qts)),
      maybe_integer_field("seq", Map.get(fields, :seq))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp format_message(
         %Decoded{tl_name: "message", fields: fields},
         peer_index
       ) do
    [
      maybe_integer_field("id", Map.get(fields, :id)),
      maybe_field("peer", Map.get(fields, :peer_id), peer_index),
      maybe_field("from", Map.get(fields, :from_id), peer_index),
      maybe_text_field("text", Map.get(fields, :message)),
      maybe_integer_field("date", Map.get(fields, :date))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_message(
         %Decoded{
           tl_name: "messageService",
           fields: fields
         },
         peer_index
       ) do
    [
      maybe_integer_field("id", Map.get(fields, :id)),
      maybe_field("peer", Map.get(fields, :peer_id), peer_index),
      maybe_field("from", Map.get(fields, :from_id), peer_index),
      maybe_service_action(Map.get(fields, :action)),
      maybe_integer_field("date", Map.get(fields, :date))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_message(decoded, _peer_index), do: format_decoded_name(decoded)

  defp maybe_service_action(%Decoded{tl_name: tl_name}),
    do: "action=#{tl_name}"

  defp maybe_service_action(_action), do: nil

  defp maybe_text_field(_label, nil), do: nil

  defp maybe_text_field(label, text) when is_binary(text) do
    "#{label}=#{inspect(compact_text(text))}"
  end

  defp maybe_text_field(_label, _text), do: nil

  defp maybe_field(_label, nil, _peer_index), do: nil

  defp maybe_field(label, %Decoded{} = peer, peer_index) do
    "#{label}=#{format_peer(peer, peer_index)}"
  end

  defp maybe_field(_label, _value, _peer_index), do: nil

  defp maybe_integer_field(_label, nil), do: nil

  defp maybe_integer_field(label, value) when is_integer(value) do
    "#{label}=#{value}"
  end

  defp maybe_integer_field(_label, _value), do: nil

  defp format_peer(
         %Decoded{tl_name: "peerUser", fields: %{user_id: user_id}},
         peer_index
       ) do
    Map.get(peer_index, {:user, user_id}, "user##{user_id}")
  end

  defp format_peer(
         %Decoded{tl_name: "peerChat", fields: %{chat_id: chat_id}},
         peer_index
       ) do
    Map.get(peer_index, {:chat, chat_id}, "chat##{chat_id}")
  end

  defp format_peer(
         %Decoded{tl_name: "peerChannel", fields: %{channel_id: channel_id}},
         peer_index
       ) do
    Map.get(peer_index, {:channel, channel_id}, "channel##{channel_id}")
  end

  defp format_peer(%Decoded{} = peer, _peer_index),
    do: format_decoded_name(peer)

  defp build_peer_index(context) do
    Enum.reduce(context.users ++ context.chats, %{}, fn decoded, acc ->
      case peer_key(decoded) do
        nil -> acc
        key -> Map.put(acc, key, peer_label(decoded))
      end
    end)
  end

  defp peer_key(%Decoded{tl_name: tl_name, fields: %{id: id}})
       when tl_name in ["user", "userEmpty"] and is_integer(id) do
    {:user, id}
  end

  defp peer_key(%Decoded{tl_name: tl_name, fields: %{id: id}})
       when tl_name in ["chat", "chatForbidden"] and is_integer(id) do
    {:chat, id}
  end

  defp peer_key(%Decoded{tl_name: tl_name, fields: %{id: id}})
       when tl_name in ["channel", "channelForbidden"] and is_integer(id) do
    {:channel, id}
  end

  defp peer_key(_decoded), do: nil

  defp peer_label(%Decoded{tl_name: tl_name, fields: fields})
       when tl_name in ["user", "userEmpty"] do
    user_id = Map.get(fields, :id)
    username = Map.get(fields, :username)
    first_name = Map.get(fields, :first_name)
    last_name = Map.get(fields, :last_name)

    cond do
      is_binary(username) and username != "" ->
        "@#{username}"

      is_binary(first_name) and is_binary(last_name) and last_name != "" ->
        "#{first_name} #{last_name}"

      is_binary(first_name) and first_name != "" ->
        first_name

      true ->
        "user##{user_id}"
    end
  end

  defp peer_label(%Decoded{tl_name: tl_name, fields: fields})
       when tl_name in [
              "chat",
              "chatForbidden",
              "channel",
              "channelForbidden"
            ] do
    Map.get(fields, :title) || "#{tl_name}##{Map.get(fields, :id, "?")}"
  end

  defp peer_label(decoded), do: format_decoded_name(decoded)

  defp compact_text(text) do
    text
    |> String.replace("\n", "\\n")
    |> String.trim()
    |> truncate(120)
  end

  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length),
    do: binary_part(text, 0, max_length - 3) <> "..."

  defp format_decoded_name(%Decoded{tl_name: tl_name}), do: tl_name

  defp format_decoded_name(decoded),
    do: inspect(decoded, pretty: true, limit: :infinity)

  defp send_ping(client, context, loop_state) do
    case Client.ping(client, loop_state.next_ping_id) do
      :ok ->
        follow_loop(
          client,
          context,
          %{
            loop_state
            | next_ping_id: loop_state.next_ping_id + 1,
              next_ping_at:
                maybe_next_ping_at(now_ms(), loop_state.ping_interval)
          }
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_print_async_event(_kind, _event, %{verbose?: false}), do: :ok

  defp maybe_print_async_event(kind, event, %{verbose?: true}) do
    IO.puts("[#{timestamp()}] #{kind}: #{inspect(event, pretty: true)}")
  end

  defp print_summary(summary) do
    IO.puts("Stopped on #{Telegram.format_endpoint(summary.endpoint)}")
    IO.puts("Session id: #{summary.session_id}")
    IO.puts("Final state: #{format_update_state(summary.update_state)}")
  end

  defp format_update_state(%UpdateState{} = update_state) do
    "pts=#{update_state.pts} qts=#{update_state.qts} date=#{update_state.date} seq=#{update_state.seq}"
  end

  defp deadline(opts) do
    case Keyword.get(opts, :duration) do
      duration when is_integer(duration) and duration >= 0 ->
        now_ms() + duration

      _ ->
        nil
    end
  end

  defp poll_interval(opts) do
    Keyword.get(opts, :poll_interval, @default_poll_interval)
  end

  defp ping_interval(opts) do
    case Keyword.get(opts, :ping_interval, @default_ping_interval) do
      interval when is_integer(interval) and interval > 0 -> interval
      _ -> nil
    end
  end

  defp maybe_next_ping_at(_now, nil), do: nil
  defp maybe_next_ping_at(now, interval), do: now + interval

  defp next_poll_at(interval, true), do: now_ms() + interval
  defp next_poll_at(_interval, false), do: now_ms()

  defp next_timeout(loop_state) do
    [loop_state.deadline, loop_state.next_poll_at, loop_state.next_ping_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&max(&1 - now_ms(), 0))
    |> Enum.min(fn -> 1_000 end)
  end

  defp due?(nil, _now), do: false
  defp due?(target, now), do: now >= target

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_time()
    |> Time.to_iso8601()
  end

  defp validate_non_negative_integer_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, _value} -> {:error, {:invalid_option_value, key}}
      :error -> :ok
    end
  end

  defp validate_positive_integer_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, _value} -> {:error, {:invalid_option_value, key}}
      :error -> :ok
    end
  end
end
