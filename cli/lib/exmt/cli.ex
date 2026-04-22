defmodule Exmt.CLI do
  @moduledoc """
  Command-line entry point for developer-facing `exmt` commands.
  """

  alias Exmt.CLI.Commands.GetConfig

  alias Exmt.CLI.Commands.{
    Contacts,
    Dialogs,
    Follow,
    GetNearestDC,
    History,
    SendMessage,
    Whoami
  }

  alias Exmt.CLI.Commands.Auth.{SendCode, SignIn}

  @commands [
    GetConfig,
    GetNearestDC,
    Whoami,
    Contacts,
    Dialogs,
    History,
    SendMessage,
    Follow,
    SendCode,
    SignIn
  ]

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

      ["help" | path] ->
        print_help(path)

      command_path ->
        dispatch(command_path)
    end
  end

  defp dispatch(command_path) do
    case resolve_command(command_path) do
      {:ok, command_module, args} ->
        command_module.run(args)

      {:incomplete, prefix, commands} ->
        print_usage(:stderr, prefix, commands)
        {:error, {:missing_subcommand, prefix}}

      :error ->
        IO.puts(
          :stderr,
          "error: unknown command #{inspect(Enum.join(command_path, " "))}"
        )

        print_usage(:stderr)
        {:error, {:unknown_command, command_path}}
    end
  end

  defp print_help(path) do
    case find_exact_command(path) do
      {:ok, command_module} ->
        IO.puts(command_module.usage())
        :ok

      :error ->
        case commands_with_prefix(path) do
          [] ->
            IO.puts(
              :stderr,
              "error: unknown command #{inspect(Enum.join(path, " "))}"
            )

            print_usage(:stderr)
            {:error, {:unknown_command, path}}

          commands ->
            print_usage(:stdio, path, commands)
            :ok
        end
    end
  end

  defp print_usage(device, prefix \\ [], commands \\ @commands)

  defp print_usage(device, [], commands) do
    IO.puts(device, """
    usage:
      exmt help
      exmt help get-config
      exmt get-config
      exmt get-nearest-dc
      exmt whoami
      exmt contacts
      exmt dialogs
      exmt history --peer self
      exmt send-message --peer self "hello from exmt"
      exmt follow
      exmt auth send-code <phone-number>
      exmt auth sign-in <phone-number> <phone-code-hash> <phone-code>

    commands:
    #{Enum.map_join(command_paths(commands), "\n", &("  " <> &1))}
    """)
  end

  defp print_usage(device, prefix, commands) do
    IO.puts(device, """
    usage:
      exmt #{Enum.join(prefix, " ")} <subcommand>

    commands:
    #{Enum.map_join(command_paths(commands), "\n", &("  " <> &1))}
    """)
  end

  defp command_paths(commands) do
    Enum.map(commands, fn command_module ->
      Enum.join(command_module.command_path(), " ")
    end)
  end

  defp find_exact_command(path) do
    Enum.find_value(@commands, :error, fn command_module ->
      if command_module.command_path() == path do
        {:ok, command_module}
      end
    end)
  end

  defp resolve_command(path) do
    case Enum.filter(@commands, fn command_module ->
           prefix_path?(command_module.command_path(), path)
         end)
         |> Enum.sort_by(fn command_module ->
           -length(command_module.command_path())
         end) do
      [command_module | _] ->
        command_path = command_module.command_path()
        {:ok, command_module, Enum.drop(path, length(command_path))}

      [] ->
        case commands_with_prefix(path) do
          [] -> :error
          commands -> {:incomplete, path, commands}
        end
    end
  end

  defp commands_with_prefix(prefix) do
    Enum.filter(@commands, fn command_module ->
      prefix_path?(prefix, command_module.command_path())
    end)
  end

  defp prefix_path?(prefix, path) do
    Enum.take(path, length(prefix)) == prefix
  end
end
