defmodule MTProto.TL.NormalizeTest do
  use ExUnit.Case, async: true

  alias MTProto.TL.Normalize
  alias MTProto.TL.Parser
  alias MTProto.TL.Schema.TypeExpr

  test "normalizes boxed refs, bare refs, flags, and bang generics" do
    {:ok, ast} =
      Parser.parse("""
      future_salts#ae500895 req_msg_id:long now:int salts:vector<future_salt> = FutureSalts;
      inputPeerPhotoFileLocationLegacy#27d69997 flags:# big:flags.0?true peer:InputPeer volume_id:long local_id:int = InputFileLocation;
      ---functions---
      invokeWithLayer#da9b0d0d {X:Type} layer:int query:!X = X;
      """)

    schema = Normalize.normalize(ast, name: :telegram_api)

    future_salts =
      Enum.find(schema.definitions, &(&1.tl_name == "future_salts"))

    salts_param = Enum.find(future_salts.params, &(&1.field == :salts))

    assert %TypeExpr.Vector{
             boxing: :bare,
             item_type: %TypeExpr.Ref{
               kind: :constructor,
               boxing: :bare,
               name: "future_salt"
             }
           } = salts_param.type

    flagged =
      Enum.find(
        schema.definitions,
        &(&1.tl_name == "inputPeerPhotoFileLocationLegacy")
      )

    big_param = Enum.find(flagged.params, &(&1.field == :big))
    peer_param = Enum.find(flagged.params, &(&1.field == :peer))

    assert %TypeExpr.Flag{
             field: :flags,
             bit: 0,
             type: %TypeExpr.Ref{name: "true", kind: :builtin, boxing: :bare}
           } = big_param.type

    assert %TypeExpr.Ref{name: "InputPeer", kind: :type, boxing: :boxed} =
             peer_param.type

    invoke_with_layer =
      Enum.find(schema.definitions, &(&1.tl_name == "invokeWithLayer"))

    query_param = Enum.find(invoke_with_layer.params, &(&1.field == :query))

    assert %TypeExpr.Bang{
             type: %TypeExpr.Ref{name: "X", kind: :generic, boxing: :dynamic}
           } = query_param.type

    assert %TypeExpr.Ref{name: "X", kind: :generic, boxing: :dynamic} =
             invoke_with_layer.result_type
  end
end
