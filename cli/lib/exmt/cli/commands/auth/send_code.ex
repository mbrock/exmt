defmodule Exmt.CLI.Commands.Auth.SendCode do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["auth", "send-code"],
    positionals: [:phone_number],
    require: [:api_id, :api_hash],
    builder: {MTProto.Telegram.API.Auth, :sendCode},
    call_args: [:phone_number, {:context, :api_hash}]
end
