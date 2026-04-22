defmodule Exmt.CLI.Commands.Contacts do
  @moduledoc false

  use Exmt.CLI.Command,
    path: ["contacts"],
    builder: :contacts_get_contacts
end
