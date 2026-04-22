defmodule Exmt.CLI.Commands.Auth.SignIn do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["auth", "sign-in"],
    positionals: [:phone_number, :phone_code_hash, :phone_code],
    builder: {MTProto.Telegram.API.Auth, :signIn},
    call_args: [:phone_number, :phone_code_hash, :phone_code]
end
