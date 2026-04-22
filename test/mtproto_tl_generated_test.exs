defmodule MTProto.TL.GeneratedTest do
  use ExUnit.Case, async: true

  alias MTProto.TL.Codegen
  alias MTProto.TL.Schema.Schema
  alias MTProto.TL.Schema.TypeExpr

  test "generator writes plain struct modules and keeps metadata out of source" do
    tmp_dir = tmp_dir!()
    schemas_dir = Path.join(tmp_dir, "schemas")
    output_dir = Path.join(tmp_dir, "generated")
    metadata_dir = Path.join(tmp_dir, "metadata")

    File.mkdir_p!(schemas_dir)

    File.write!(
      Path.join(schemas_dir, "sample_api.tl"),
      """
      int ? = Int;
      true#3fedd339 = True;
      inputPeerEmpty#7f3b18ea = InputPeer;
      exampleThing#01020304 flags:# enabled:flags.0?true peer:InputPeer = ExampleThing;

      ---functions---
      invokeWithLayer#da9b0d0d {X:Type} layer:int query:!X = X;
      """
    )

    output_path =
      Codegen.generate_schema!(:sample_api,
        schemas_dir: schemas_dir,
        output_dir: output_dir,
        metadata_dir: metadata_dir
      )

    source = File.read!(output_path)

    refute source =~ "@definitions ["
    refute source =~ "def by_name(name)"
    refute source =~ "__struct__: MTProto.TL.Schema.Definition"

    Code.require_file(output_path)

    constructor_module =
      Module.concat([
        Codegen.base_module(:sample_api),
        Constructors,
        ExampleThing
      ])

    function_module =
      Module.concat([
        Codegen.base_module(:sample_api),
        Functions,
        InvokeWithLayer
      ])

    assert %{enabled: true, peer: :peer} =
             struct(constructor_module, enabled: true, peer: :peer)

    assert %{layer: 214, query: {:opaque, :query}} =
             struct(function_module, layer: 214, query: {:opaque, :query})

    refute function_exported?(constructor_module, :definition, 0)
    refute function_exported?(constructor_module, :fields, 0)
    refute function_exported?(constructor_module, :new, 1)

    assert %Schema{} =
             schema =
             Codegen.load_schema!(:sample_api, metadata_dir: metadata_dir)

    example_thing =
      Enum.find(schema.definitions, &(&1.tl_name == "exampleThing"))

    invoke = Enum.find(schema.definitions, &(&1.tl_name == "invokeWithLayer"))

    assert example_thing.module == constructor_module
    assert example_thing.id == 0x01020304

    enabled_param = Enum.find(example_thing.params, &(&1.field == :enabled))
    peer_param = Enum.find(example_thing.params, &(&1.field == :peer))
    query_param = Enum.find(invoke.params, &(&1.field == :query))

    assert %TypeExpr.Ref{name: "ExampleThing", kind: :type, boxing: :boxed} =
             example_thing.result_type

    assert %TypeExpr.Ref{name: "InputPeer", kind: :type, boxing: :boxed} =
             peer_param.type

    assert %TypeExpr.Flag{
             field: :flags,
             bit: 0,
             type: %TypeExpr.Ref{name: "true", kind: :builtin, boxing: :bare}
           } = enabled_param.type

    assert %TypeExpr.Bang{
             type: %TypeExpr.Ref{name: "X", kind: :generic, boxing: :dynamic}
           } = query_param.type
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "exmt-codegen-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
