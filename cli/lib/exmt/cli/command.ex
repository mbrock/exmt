defmodule Exmt.CLI.Command do
  @moduledoc false

  alias Exmt.CLI.Telegram
  alias MTProto.Telegram.{API, Client, Request}

  @callback command_path() :: [binary()]
  @callback usage() :: binary()
  @callback run([binary()]) :: :ok | {:error, term()}

  defmacro __using__(opts) do
    path = Keyword.fetch!(opts, :path)
    builder = Keyword.fetch!(opts, :builder)
    switches = Keyword.get(opts, :switches, [])
    positionals = Keyword.get(opts, :positionals, [])
    require = Keyword.get(opts, :require, [:api_id])
    call_args = Keyword.get(opts, :call_args, [])
    prepare = Keyword.get(opts, :prepare)

    quote do
      @behaviour Exmt.CLI.Command

      alias Exmt.CLI.Command

      @impl true
      def command_path, do: unquote(Macro.escape(path))

      @impl true
      def usage do
        Command.usage(
          unquote(Macro.escape(path)),
          unquote(Macro.escape(positionals)),
          unquote(Macro.escape(switches))
        )
      end

      @impl true
      def run(argv) do
        Command.run_rpc(argv,
          path: command_path(),
          usage: usage(),
          switches: unquote(Macro.escape(switches)),
          positionals: unquote(Macro.escape(positionals)),
          require: unquote(Macro.escape(require)),
          builder: unquote(builder),
          call_args: unquote(Macro.escape(call_args)),
          prepare:
            unquote(
              case prepare do
                nil -> nil
                fun_name -> quote(do: &(__MODULE__.unquote(fun_name) / 2))
              end
            )
        )
      end
    end
  end

  @spec usage([binary()], [atom()], keyword()) :: binary()
  def usage(path, positionals, _switches) do
    """
    usage:
      exmt #{Enum.join(path, " ")} [options]#{format_positionals(positionals)}
    """
  end

  @spec run_rpc([binary()], map()) :: :ok | {:error, term()}
  def run_rpc(argv, config) do
    config = Map.new(config)

    Telegram.run_command(fn ->
      with {:ok, parsed} <-
             parse_args(
               argv,
               config.switches,
               config.positionals,
               config.prepare
             ),
           {:ok, context} <-
             Telegram.build_context(parsed.opts, require: config.require),
           :ok <- Telegram.print_banner(context),
           {:ok, result} <-
             Telegram.try_endpoints(
               context,
               &invoke(&1, &2, context, parsed, config)
             ) do
        IO.inspect(result, pretty: true, limit: :infinity)
        :ok
      else
        {:error, reason} ->
          IO.puts(:stderr, "error: #{Telegram.format_error(reason)}")
          IO.puts(:stderr, config.usage)
          {:error, reason}
      end
    end)
  end

  @spec parse_peer_opt(keyword(), binary()) ::
          {:ok, term()} | {:error, term()}
  def parse_peer_opt(opts, default \\ "self") do
    opts
    |> Keyword.get(:peer, default)
    |> Telegram.parse_peer()
  end

  defp parse_args(argv, switches, positionals, prepare) do
    {opts, rest, invalid} =
      OptionParser.parse(argv, strict: Telegram.common_switches() ++ switches)

    cond do
      invalid != [] ->
        {:error, {:invalid_switches, invalid}}

      true ->
        with {:ok, args} <- parse_positionals(rest, positionals),
             {:ok, prepared} <- prepare_args(prepare, opts, args) do
          {:ok, %{opts: opts, assigns: Map.merge(args, prepared)}}
        end
    end
  end

  defp parse_positionals(rest, positionals) do
    expected = length(positionals)
    actual = length(rest)

    cond do
      actual < expected ->
        {:error,
         {:missing_argument, missing_positionals(positionals, actual)}}

      actual > expected ->
        {:error, {:unexpected_arguments, Enum.drop(rest, expected)}}

      true ->
        {:ok, Map.new(Enum.zip(positionals, rest))}
    end
  end

  defp prepare_args(nil, _opts, _args), do: {:ok, %{}}

  defp prepare_args(prepare, opts, args) when is_function(prepare, 2) do
    case prepare.(opts, args) do
      {:ok, prepared} when is_map(prepared) -> {:ok, prepared}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke(client, endpoint, context, parsed, config) do
    request_params =
      parsed.assigns
      |> Map.get(:request_opts, [])
      |> Keyword.merge(
        resolve_call_args(config.call_args, parsed.assigns, context)
      )

    exec_opts = Telegram.request_opts(context)

    with {:ok, request} <-
           build_request(config.builder, request_params),
         {:ok, decoded} <- Client.request_sync(client, request, exec_opts),
         session_id <- Client.session_id(client) do
      {:ok, %{endpoint: endpoint, session_id: session_id, decoded: decoded}}
    end
  end

  defp resolve_call_args(call_args, assigns, context) do
    Enum.map(call_args, fn
      {:context, key} -> {key, Map.fetch!(context, key)}
      key when is_atom(key) -> {key, Map.fetch!(assigns, key)}
    end)
  end

  defp build_request({module, function}, request_params) do
    {:ok, apply(module, function, [request_params])}
  end

  defp build_request(builder, request_params) when is_atom(builder) do
    case apply(API, builder, [request_params]) do
      %Request{} = request -> {:ok, request}
      {:ok, %Request{} = request} -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_positionals([]), do: ""

  defp format_positionals(positionals) do
    " " <> Enum.map_join(positionals, " ", &format_positional/1)
  end

  defp missing_positionals(positionals, consumed) do
    positionals
    |> Enum.drop(consumed)
    |> Enum.map_join(" ", &format_positional/1)
  end

  defp format_positional(name) do
    "<" <> (name |> Atom.to_string() |> String.replace("_", "-")) <> ">"
  end
end
