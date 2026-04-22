defmodule Exmt.CLI.Commands.Auth.SignIn do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["auth", "sign-in"],
    positionals: [:phone_number, :phone_code_hash, :phone_code],
    builder: :auth_sign_in,
    call_args: [:phone_number, :phone_code_hash, :phone_code]
end
