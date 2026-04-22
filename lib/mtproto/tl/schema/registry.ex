defmodule MTProto.TL.Schema.Registry do
  @moduledoc """
  Indexed accessors for vendored TL schemas.
  """

  alias MTProto.TL.Schema.Definition
  alias MTProto.TL.Schema.TypeExpr
  alias MTProto.TL.VendoredSchema

  @schema_names VendoredSchema.available_schemas()

  build_index = fn schema ->
    definitions_by_name = Map.new(schema.definitions, &{&1.tl_name, &1})

    functions_by_name =
      definitions_by_name
      |> Map.values()
      |> Enum.filter(&(&1.kind == :function))
      |> Map.new(&{&1.tl_name, &1})

    constructors_by_name =
      definitions_by_name
      |> Map.values()
      |> Enum.filter(&(&1.kind == :constructor))
      |> Map.new(&{&1.tl_name, &1})

    constructors_by_type =
      constructors_by_name
      |> Map.values()
      |> Enum.group_by(fn definition ->
        case definition do
          %Definition{result_type: %TypeExpr.Ref{name: name}} -> name
          %Definition{} -> nil
        end
      end)

    %{
      definitions_by_name: definitions_by_name,
      functions_by_name: functions_by_name,
      constructors_by_name: constructors_by_name,
      constructors_by_type: constructors_by_type,
      available_methods:
        functions_by_name
        |> Map.keys()
        |> Enum.sort()
    }
  end

  @indexes (for schema_name <- @schema_names, into: %{} do
              {:ok, schema} = VendoredSchema.load(schema_name)
              {schema_name, build_index.(schema)}
            end)

  @spec available_schemas() :: [atom()]
  def available_schemas, do: @schema_names

  @spec available?(atom()) :: boolean()
  def available?(schema_name), do: Map.has_key?(@indexes, schema_name)

  @spec definition(atom(), binary()) :: {:ok, Definition.t()} | :error
  def definition(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case fetch_index(schema_name) do
      {:ok, %{definitions_by_name: definitions_by_name}} ->
        case Map.fetch(definitions_by_name, name) do
          {:ok, definition} -> {:ok, definition}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  @spec definition!(atom(), binary()) :: Definition.t()
  def definition!(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case definition(schema_name, name) do
      {:ok, definition} ->
        definition

      :error ->
        raise ArgumentError,
              missing_entry_message(schema_name, :definition, name)
    end
  end

  @spec function(atom(), binary()) :: {:ok, Definition.t()} | :error
  def function(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case fetch_index(schema_name) do
      {:ok, %{functions_by_name: functions_by_name}} ->
        case Map.fetch(functions_by_name, name) do
          {:ok, definition} -> {:ok, definition}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  @spec function!(atom(), binary()) :: Definition.t()
  def function!(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case function(schema_name, name) do
      {:ok, definition} ->
        definition

      :error ->
        raise ArgumentError,
              missing_entry_message(schema_name, :function, name)
    end
  end

  @spec constructor(atom(), binary()) :: {:ok, Definition.t()} | :error
  def constructor(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case fetch_index(schema_name) do
      {:ok, %{constructors_by_name: constructors_by_name}} ->
        case Map.fetch(constructors_by_name, name) do
          {:ok, definition} -> {:ok, definition}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  @spec constructor!(atom(), binary()) :: Definition.t()
  def constructor!(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case constructor(schema_name, name) do
      {:ok, definition} ->
        definition

      :error ->
        raise ArgumentError,
              missing_entry_message(schema_name, :constructor, name)
    end
  end

  @spec constructors_for_type(atom(), binary()) :: [Definition.t()]
  def constructors_for_type(schema_name, type_name)
      when is_atom(schema_name) and is_binary(type_name) do
    case fetch_index(schema_name) do
      {:ok, %{constructors_by_type: constructors_by_type}} ->
        Map.get(constructors_by_type, type_name, [])

      :error ->
        []
    end
  end

  @spec result_type(atom(), binary()) :: {:ok, binary() | nil} | :error
  def result_type(schema_name, name)
      when is_atom(schema_name) and is_binary(name) do
    case definition(schema_name, name) do
      {:ok, definition} -> {:ok, result_type_name(definition)}
      :error -> :error
    end
  end

  @spec available_methods(atom()) :: [binary()]
  def available_methods(schema_name) when is_atom(schema_name) do
    case fetch_index(schema_name) do
      {:ok, %{available_methods: available_methods}} ->
        available_methods

      :error ->
        raise ArgumentError, "schema #{inspect(schema_name)} is not indexed"
    end
  end

  @spec result_type_name(Definition.t()) :: binary() | nil
  def result_type_name(%Definition{
        result_type: %TypeExpr.Ref{name: name}
      }),
      do: name

  def result_type_name(%Definition{}), do: nil

  defp fetch_index(schema_name) do
    case Map.fetch(@indexes, schema_name) do
      {:ok, index} -> {:ok, index}
      :error -> :error
    end
  end

  defp missing_entry_message(schema_name, kind, name) do
    "#{kind} #{inspect(name)} is not indexed for schema #{inspect(schema_name)}"
  end
end
