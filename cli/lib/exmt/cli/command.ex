defmodule Exmt.CLI.Command do
  @moduledoc false

  @callback command_path() :: [binary()]
  @callback aliases() :: [[binary()]]
  @callback summary() :: binary()
  @callback usage() :: binary()
  @callback run([binary()]) :: :ok | {:error, term()}
end
