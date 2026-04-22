defmodule MTProto.TL.VendoredSchemaTest do
  use ExUnit.Case, async: true

  alias MTProto.TL.Schema.TypeExpr
  alias MTProto.TL.VendoredSchema

  test "loads vendored telegram schema with generic wrapper methods" do
    assert {:ok, schema} = VendoredSchema.load(:telegram_api)

    invoke_with_layer =
      Enum.find(schema.definitions, &(&1.tl_name == "invokeWithLayer"))

    assert invoke_with_layer.kind == :function
    assert Enum.map(invoke_with_layer.generics, & &1.name) == ["X"]

    query_param = Enum.find(invoke_with_layer.params, &(&1.field == :query))

    assert %TypeExpr.Bang{
             type: %TypeExpr.Ref{
               name: "X",
               kind: :generic,
               boxing: :dynamic
             }
           } = query_param.type

    assert %TypeExpr.Ref{name: "X", kind: :generic, boxing: :dynamic} =
             invoke_with_layer.result_type
  end

  test "loads vendored mtproto schema without parsing tl source files" do
    assert {:ok, schema} = VendoredSchema.load(:mtproto_api)

    assert Enum.any?(schema.definitions, &(&1.tl_name == "rpc_error"))

    future_salts =
      Enum.find(schema.definitions, &(&1.tl_name == "future_salts"))

    salts_param = Enum.find(future_salts.params, &(&1.field == :salts))

    assert %TypeExpr.Vector{
             boxing: :bare,
             item_type: %TypeExpr.Ref{
               name: "future_salt",
               kind: :constructor,
               boxing: :bare
             }
           } = salts_param.type

    vector =
      Enum.find(schema.definitions, &(&1.tl_name == "vector"))

    assert Enum.map(vector.generics, & &1.name) == ["t"]

    assert %TypeExpr.Vector{
             boxing: :boxed,
             item_type: %TypeExpr.Ref{
               name: "t",
               kind: :generic,
               boxing: :dynamic
             }
           } = vector.result_type
  end
end
