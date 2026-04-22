defmodule MTProto.Telegram.Schema do
  @moduledoc false

  alias MTProto.TL.Schema.Definition
  alias MTProto.TL.Schema.TypeExpr
  alias MTProto.TL.VendoredSchema

  {:ok, schema} = VendoredSchema.load(:telegram_api)

  @definitions_by_name Map.new(schema.definitions, &{&1.tl_name, &1})

  @functions_by_name Map.new(
                       Enum.filter(
                         schema.definitions,
                         &(&1.kind == :function)
                       ),
                       &{&1.tl_name, &1}
                     )

  @constructors_by_name Map.new(
                          Enum.filter(
                            schema.definitions,
                            &(&1.kind == :constructor)
                          ),
                          &{&1.tl_name, &1}
                        )

  @constructors_by_type Enum.group_by(
                          Map.values(@constructors_by_name),
                          fn definition ->
                            case definition do
                              %Definition{
                                result_type: %TypeExpr.Ref{name: name}
                              } ->
                                name

                              %Definition{} ->
                                nil
                            end
                          end
                        )

  @spec definition(binary()) :: {:ok, Definition.t()} | :error
  def definition(name) when is_binary(name) do
    case Map.fetch(@definitions_by_name, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> :error
    end
  end

  @spec definition!(binary()) :: Definition.t()
  def definition!(name) when is_binary(name) do
    Map.fetch!(@definitions_by_name, name)
  end

  @spec function(binary()) :: {:ok, Definition.t()} | :error
  def function(name) when is_binary(name) do
    case Map.fetch(@functions_by_name, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> :error
    end
  end

  @spec function!(binary()) :: Definition.t()
  def function!(name) when is_binary(name) do
    Map.fetch!(@functions_by_name, name)
  end

  @spec constructor(binary()) :: {:ok, Definition.t()} | :error
  def constructor(name) when is_binary(name) do
    case Map.fetch(@constructors_by_name, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> :error
    end
  end

  @spec constructor!(binary()) :: Definition.t()
  def constructor!(name) when is_binary(name) do
    Map.fetch!(@constructors_by_name, name)
  end

  @spec constructors_for_type(binary()) :: [Definition.t()]
  def constructors_for_type(type_name) when is_binary(type_name) do
    Map.get(@constructors_by_type, type_name, [])
  end

  @spec result_type(binary()) :: {:ok, binary() | nil} | :error
  def result_type(name) when is_binary(name) do
    case definition(name) do
      {:ok, definition} -> {:ok, result_type_name(definition)}
      :error -> :error
    end
  end

  @spec available_methods() :: [binary()]
  def available_methods do
    @functions_by_name
    |> Map.keys()
    |> Enum.sort()
  end

  @spec result_type_name(Definition.t()) :: binary() | nil
  def result_type_name(%Definition{
        result_type: %TypeExpr.Ref{name: name}
      }),
      do: name

  def result_type_name(%Definition{}), do: nil
end
