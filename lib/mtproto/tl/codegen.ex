defmodule MTProto.TL.Codegen do
  @moduledoc """
  Generates Elixir source files from vendored TL schemas using quoted AST.

  We currently keep this around as a reference implementation for AST-based
  code generation, even though generated artifacts are not checked into the
  repo. It gives us a working pattern to reuse later if a concrete codegen
  need comes back.
  """

  alias MTProto.TL.Normalize
  alias MTProto.TL.Parser
  alias MTProto.TL.Schema

  @default_output_dir Path.expand("lib/mtproto/tl/generated", File.cwd!())
  @default_metadata_dir Path.expand("priv/tl/generated", File.cwd!())
  @default_schemas_dir Path.expand("priv/tl", File.cwd!())

  @spec available_schema_names(keyword()) :: [atom()]
  def available_schema_names(opts \\ []) do
    schemas_dir = Keyword.get(opts, :schemas_dir, @default_schemas_dir)

    schemas_dir
    |> Path.join("*.tl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      path
      |> Path.basename(".tl")
      |> String.to_atom()
    end)
  end

  @spec generate_all!(keyword()) :: [Path.t()]
  def generate_all!(opts \\ []) do
    schema_names =
      Keyword.get_lazy(opts, :schema_names, fn ->
        available_schema_names(opts)
      end)

    Enum.map(schema_names, &generate_schema!(&1, opts))
  end

  @spec generate_schema!(atom() | binary(), keyword()) :: Path.t()
  def generate_schema!(schema_name, opts \\ []) do
    schema_name = normalize_schema_name(schema_name)
    schemas_dir = Keyword.get(opts, :schemas_dir, @default_schemas_dir)
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    metadata_dir = Keyword.get(opts, :metadata_dir, @default_metadata_dir)

    source_path = Path.join(schemas_dir, "#{schema_name}.tl")

    {:ok, parsed_schema} = Parser.parse_file(source_path)
    normalized_schema = Normalize.normalize(parsed_schema, name: schema_name)

    definitions =
      Enum.map(normalized_schema.definitions, fn definition ->
        %{definition | module: module_for_definition(schema_name, definition)}
      end)

    schema = %Schema.Schema{name: schema_name, definitions: definitions}
    output_path = Path.join(output_dir, "#{schema_name}.ex")
    metadata_path = Path.join(metadata_dir, "#{schema_name}.term")

    File.mkdir_p!(output_dir)
    File.mkdir_p!(metadata_dir)
    File.write!(output_path, render_schema(schema))
    File.write!(metadata_path, :erlang.term_to_binary(schema, compressed: 9))
    output_path
  end

  @spec metadata_path(atom() | binary(), keyword()) :: Path.t()
  def metadata_path(schema_name, opts \\ []) do
    schema_name = normalize_schema_name(schema_name)
    metadata_dir = Keyword.get(opts, :metadata_dir, @default_metadata_dir)
    Path.join(metadata_dir, "#{schema_name}.term")
  end

  @spec load_schema!(atom() | binary(), keyword()) :: Schema.Schema.t()
  def load_schema!(schema_name, opts \\ []) do
    schema_name
    |> metadata_path(opts)
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  def render_schema(%Schema.Schema{} = schema) do
    schema
    |> schema_ast()
    |> Code.quoted_to_algebra()
    |> Inspect.Algebra.format(98)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @spec base_module(atom()) :: module()
  def base_module(schema_name) do
    Module.concat([MTProto, TL, Generated, camelize_schema(schema_name)])
  end

  defp schema_ast(%Schema.Schema{} = schema) do
    base_module = base_module(schema.name)
    constructors_module = Module.concat(base_module, "Constructors")
    functions_module = Module.concat(base_module, "Functions")

    definition_modules =
      Enum.map(schema.definitions, &definition_module_ast(&1))

    quote do
      defmodule unquote(base_module) do
        @moduledoc false
      end

      defmodule unquote(constructors_module) do
        @moduledoc false
      end

      defmodule unquote(functions_module) do
        @moduledoc false
      end

      unquote_splicing(definition_modules)
    end
  end

  defp definition_module_ast(definition) do
    fields =
      definition.params
      |> Enum.map(& &1.field)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&{&1, nil})

    quote do
      defmodule unquote(definition.module) do
        @moduledoc false

        defstruct unquote(fields)
      end
    end
  end

  defp module_for_definition(schema_name, definition) do
    kind_segment =
      case definition.kind do
        :function -> "Functions"
        :constructor -> "Constructors"
      end

    name_segments =
      definition.tl_name
      |> String.split(".")
      |> Enum.map(&Macro.camelize/1)

    Module.concat([base_module(schema_name), kind_segment | name_segments])
  end

  defp camelize_schema(schema_name) do
    schema_name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(&camelize_schema_segment/1)
  end

  defp camelize_schema_segment("mtproto"), do: "MTProto"
  defp camelize_schema_segment(segment), do: Macro.camelize(segment)

  defp normalize_schema_name(schema_name) when is_atom(schema_name),
    do: schema_name

  defp normalize_schema_name(schema_name) when is_binary(schema_name) do
    schema_name
    |> String.trim()
    |> String.trim_trailing(".tl")
    |> String.to_atom()
  end
end
