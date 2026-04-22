defmodule MTProto.TL.ParserTest do
  use ExUnit.Case, async: true

  alias MTProto.TL.AST
  alias MTProto.TL.AST.Definition
  alias MTProto.TL.AST.Expr.Application
  alias MTProto.TL.AST.Expr.Conditional
  alias MTProto.TL.AST.Expr.Group
  alias MTProto.TL.AST.Expr.Number
  alias MTProto.TL.AST.Expr.Prefix
  alias MTProto.TL.AST.Expr.Reference
  alias MTProto.TL.AST.Expr.Repetition
  alias MTProto.TL.AST.Expr.Special
  alias MTProto.TL.AST.Generic
  alias MTProto.TL.AST.Param
  alias MTProto.TL.Parser

  test "parses generic constructors with anonymous params" do
    assert {:ok, definition} =
             Parser.parse_definition(
               "vector#1cb5c415 {t:Type} # [ t ] = Vector t;"
             )

    assert definition == %Definition{
             name: "vector",
             id: 0x1CB5C415,
             kind: :constructor,
             section: nil,
             generics: [
               %Generic{name: "t", kind: %Reference{name: "Type"}}
             ],
             params: [
               %Param{name: nil, type: %Special{value: "#"}},
               %Param{
                 name: nil,
                 type: %Group{
                   delimiter: :square,
                   items: [%Reference{name: "t"}]
                 }
               }
             ],
             result: %Application{
               callee: %Reference{name: "Vector"},
               args: [%Reference{name: "t"}],
               syntax: :juxtaposition
             },
             line: 1
           }
  end

  test "parses repetition and conditional expressions" do
    assert {:ok, repeated} =
             Parser.parse_definition("int128 4*[ int ] = Int128;")

    assert repeated.params == [
             %Param{
               name: nil,
               type: %Repetition{
                 multiplier: %Number{value: 4},
                 expr: %Group{
                   delimiter: :square,
                   items: [%Reference{name: "int"}]
                 }
               }
             }
           ]

    assert {:ok, flagged} =
             Parser.parse_definition(
               "inputPeerPhotoFileLocationLegacy#27d69997 flags:# big:flags.0?true peer:InputPeer volume_id:long local_id:int = InputFileLocation;"
             )

    assert flagged.params == [
             %Param{name: "flags", type: %Special{value: "#"}},
             %Param{
               name: "big",
               type: %Conditional{
                 guard: %Reference{name: "flags.0"},
                 expr: %Reference{name: "true"}
               }
             },
             %Param{name: "peer", type: %Reference{name: "InputPeer"}},
             %Param{name: "volume_id", type: %Reference{name: "long"}},
             %Param{name: "local_id", type: %Reference{name: "int"}}
           ]
  end

  test "parses functions with type parameters and prefixed refs" do
    assert {:ok, definition} =
             Parser.parse_definition(
               "invokeWithLayer#da9b0d0d {X:Type} layer:int query:!X = X;",
               section: :functions,
               line: 42
             )

    assert definition.kind == :function
    assert definition.section == :functions
    assert definition.line == 42

    assert definition.generics == [
             %Generic{name: "X", kind: %Reference{name: "Type"}}
           ]

    assert definition.params == [
             %Param{name: "layer", type: %Reference{name: "int"}},
             %Param{
               name: "query",
               type: %Prefix{
                 operator: :!,
                 expr: %Reference{name: "X"}
               }
             }
           ]

    assert definition.result == %Reference{name: "X"}
  end

  test "parses complete vendored schemas" do
    assert {:ok, mtproto_schema} =
             Parser.parse_file(
               Path.expand("../priv/tl/mtproto_api.tl", __DIR__)
             )

    assert {:ok, telegram_schema} =
             Parser.parse_file(
               Path.expand("../priv/tl/telegram_api.tl", __DIR__)
             )

    mtproto_definitions = AST.definitions(mtproto_schema)
    telegram_definitions = AST.definitions(telegram_schema)

    assert length(mtproto_definitions) > 20
    assert length(telegram_definitions) > 2000

    assert Enum.any?(mtproto_definitions, fn definition ->
             definition.name == "req_pq_multi" and
               definition.kind == :function
           end)

    assert Enum.any?(mtproto_definitions, fn definition ->
             definition.name == "resPQ" and definition.kind == :constructor
           end)

    assert Enum.any?(telegram_definitions, fn definition ->
             definition.name == "invokeWithLayer" and
               definition.kind == :function
           end)

    assert Enum.any?(telegram_definitions, fn definition ->
             definition.name == "inputPeerEmpty" and
               definition.kind == :constructor
           end)
  end
end
