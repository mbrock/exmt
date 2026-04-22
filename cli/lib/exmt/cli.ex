defmodule Exmt.CLI do
  @moduledoc """
  Command-line entry point for developer-facing `exmt` commands.
  """

  alias Exmt.CLI.Commands.GetConfig

  @commands [GetConfig]

  @spec main([binary()]) :: no_return()
  def main(argv) do
    case run(argv) do
      :ok -> System.halt(0)
      {:error, _reason} -> System.halt(1)
    end
  end

  @spec run([binary()]) :: :ok | {:error, term()}
  def run(argv) do
    case argv do
      [] ->
        print_usage(:stdio)
        :ok

      ["help"] ->
        print_usage(:stdio)
        :ok

      ["help", command_name] ->
        print_command_usage(command_name)

      [command_name | args] ->
        dispatch(command_name, args)
    end
  end

  defp dispatch(command_name, args) do
    case find_command(command_name) do
      {:ok, command_module} ->
        command_module.run(args)

      :error ->
        IO.puts(:stderr, "error: unknown command #{inspect(command_name)}")
        print_usage(:stderr)
        {:error, {:unknown_command, command_name}}
    end
  end

  defp print_command_usage(command_name) do
    case find_command(command_name) do
      {:ok, command_module} ->
        IO.puts(command_module.usage())
        :ok

      :error ->
        IO.puts(:stderr, "error: unknown command #{inspect(command_name)}")
        print_usage(:stderr)
        {:error, {:unknown_command, command_name}}
    end
  end

  defp print_usage(device) do
    IO.puts(device, """
    usage:
      exmt help
      exmt get-config

    commands:
    #{Enum.map_join(command_summaries(), "\n", &("  " <> &1))}
    """)
  end

  defp command_summaries do
    Enum.map(@commands, fn command_module ->
      aliases =
        case command_module.aliases() do
          [] -> ""
          aliases -> " (" <> Enum.join(aliases, ", ") <> ")"
        end

      "#{command_module.command()}#{aliases}  #{command_module.summary()}"
    end)
  end

  defp find_command(command_name) do
    Enum.find_value(@commands, :error, fn command_module ->
      names = [command_module.command() | command_module.aliases()]

      if command_name in names do
        {:ok, command_module}
      end
    end)
  end
end
