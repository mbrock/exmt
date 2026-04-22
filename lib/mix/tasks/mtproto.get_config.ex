defmodule Mix.Tasks.Mtproto.GetConfig do
  use Mix.Task

  @shortdoc "Perform help.getConfig using the MTProto client"

  @moduledoc """
  Performs a live `help.getConfig` request against Telegram using `MTProto.Client`.

      mix mtproto.get_config
      mix mtproto.get_config --session-file .exmt/dev.term --verbose
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case MTProto.Playground.GetConfig.run(args) do
      :ok -> :ok
      {:error, _reason} -> Mix.raise("mtproto.get_config failed")
    end
  end
end
