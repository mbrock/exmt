defmodule MTProto.TL.Schema.RegistryTest do
  use ExUnit.Case, async: true

  alias MTProto.TL.Schema.Registry

  test "lists indexed vendored schemas" do
    assert :mtproto_api in Registry.available_schemas()
    assert :telegram_api in Registry.available_schemas()
    assert Registry.available?(:telegram_api)
    refute Registry.available?(:unknown_schema)
  end

  test "looks up telegram functions and constructors by schema name" do
    assert {:ok, function} =
             Registry.function(:telegram_api, "help.getConfig")

    assert function.tl_name == "help.getConfig"
    assert function.kind == :function

    assert {:ok, constructor} =
             Registry.constructor(:telegram_api, "inputUserSelf")

    assert constructor.tl_name == "inputUserSelf"
    assert constructor.kind == :constructor
  end

  test "groups constructors by result type" do
    constructors = Registry.constructors_for_type(:telegram_api, "InputUser")

    assert Enum.any?(constructors, &(&1.tl_name == "inputUserSelf"))
  end
end
