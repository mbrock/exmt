defmodule MTProto.TL.Normalize do
  @moduledoc """
  Converts the raw parser AST into a schema IR suitable for generation.
  """

  alias MTProto.TL.AST
  alias MTProto.TL.AST.Expr
  alias MTProto.TL.Schema.Definition
  alias MTProto.TL.Schema.Generic
  alias MTProto.TL.Schema.Param
  alias MTProto.TL.Schema.Schema, as: NormalizedSchema
  alias MTProto.TL.Schema.TypeExpr

  @bare_builtins MapSet.new(
                   ~w(int int32 int53 int64 int128 int256 long double string bytes true)
                 )
  @vector_names MapSet.new(~w(vector Vector))

  def normalize(%AST.Schema{} = schema, opts) do
    name = Keyword.fetch!(opts, :name)

    definitions =
      schema
      |> AST.definitions()
      |> Enum.map(&normalize_definition(&1, name))

    %NormalizedSchema{name: name, definitions: definitions}
  end

  defp normalize_definition(%AST.Definition{} = definition, schema_name) do
    generics =
      Enum.map(definition.generics, fn %AST.Generic{name: name, kind: kind} ->
        %Generic{name: name, kind: normalize_expr(kind, empty_context())}
      end)

    context = %{generic_names: MapSet.new(generics, & &1.name)}

    params =
      Enum.map(definition.params, fn %AST.Param{name: name, type: type} ->
        %Param{
          field: normalize_field_name(name),
          tl_name: name,
          type: normalize_expr(type, context)
        }
      end)

    %Definition{
      schema: schema_name,
      kind: definition.kind,
      tl_name: definition.name,
      id: definition.id,
      generics: generics,
      params: params,
      result_type: normalize_expr(definition.result, context),
      line: definition.line
    }
  end

  defp normalize_expr(%Expr.Reference{name: name}, %{
         generic_names: generic_names
       }) do
    segments = String.split(name, ".")

    cond do
      MapSet.member?(generic_names, name) ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :generic,
          boxing: :dynamic
        }

      MapSet.member?(@bare_builtins, name) ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :builtin,
          boxing: :bare
        }

      boxed_reference?(name) ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :type,
          boxing: :boxed
        }

      true ->
        %TypeExpr.Ref{
          name: name,
          segments: segments,
          kind: :constructor,
          boxing: :bare
        }
    end
  end

  defp normalize_expr(%Expr.Number{value: value}, _context),
    do: %TypeExpr.Number{value: value}

  defp normalize_expr(%Expr.Special{value: value}, _context),
    do: %TypeExpr.Special{value: value}

  defp normalize_expr(
         %Expr.Group{delimiter: delimiter, items: items},
         context
       ) do
    %TypeExpr.Group{
      delimiter: delimiter,
      items: Enum.map(items, &normalize_expr(&1, context))
    }
  end

  defp normalize_expr(
         %Expr.Repetition{multiplier: multiplier, expr: expr},
         context
       ) do
    %TypeExpr.Repetition{
      multiplier: normalize_expr(multiplier, context),
      type: normalize_expr(expr, context)
    }
  end

  defp normalize_expr(%Expr.Prefix{operator: :!, expr: expr}, context) do
    %TypeExpr.Bang{type: normalize_expr(expr, context)}
  end

  defp normalize_expr(%Expr.Prefix{operator: :%, expr: expr}, context) do
    %TypeExpr.Bare{type: normalize_expr(expr, context)}
  end

  defp normalize_expr(%Expr.Prefix{operator: operator, expr: expr}, context) do
    %TypeExpr.Application{
      callee: %TypeExpr.Special{value: Atom.to_string(operator)},
      args: [normalize_expr(expr, context)],
      syntax: :prefix
    }
  end

  defp normalize_expr(%Expr.Conditional{guard: guard, expr: expr}, context) do
    case parse_flag_guard(guard) do
      {:ok, field_name, bit} ->
        %TypeExpr.Flag{
          field: String.to_atom(field_name),
          tl_name: field_name,
          bit: bit,
          type: normalize_expr(expr, context)
        }

      :error ->
        %TypeExpr.Conditional{
          guard: normalize_expr(guard, context),
          type: normalize_expr(expr, context)
        }
    end
  end

  defp normalize_expr(
         %Expr.Application{
           callee: %Expr.Reference{name: name},
           args: [arg],
           syntax: syntax
         },
         context
       ) do
    if MapSet.member?(@vector_names, name) do
      callee = normalize_expr(%Expr.Reference{name: name}, context)

      %TypeExpr.Vector{
        item_type: normalize_expr(arg, context),
        boxing: callee.boxing
      }
      |> maybe_wrap_vector_application(syntax, callee)
    else
      %TypeExpr.Application{
        callee: normalize_expr(%Expr.Reference{name: name}, context),
        args: [normalize_expr(arg, context)],
        syntax: syntax
      }
    end
  end

  defp normalize_expr(
         %Expr.Application{callee: callee, args: args, syntax: syntax},
         context
       ) do
    %TypeExpr.Application{
      callee: normalize_expr(callee, context),
      args: Enum.map(args, &normalize_expr(&1, context)),
      syntax: syntax
    }
  end

  defp maybe_wrap_vector_application(
         %TypeExpr.Vector{} = vector,
         _syntax,
         _callee
       ),
       do: vector

  defp parse_flag_guard(%Expr.Reference{name: guard}) do
    case Regex.run(~r/^([a-z_][a-zA-Z0-9_]*)\.(\d+)$/, guard) do
      [_, field_name, bit] -> {:ok, field_name, String.to_integer(bit)}
      _ -> :error
    end
  end

  defp parse_flag_guard(_), do: :error

  defp boxed_reference?(name) do
    name
    |> String.split(".")
    |> List.last()
    |> String.match?(~r/^[A-Z]/)
  end

  defp normalize_field_name(nil), do: nil
  defp normalize_field_name(name), do: String.to_atom(name)

  defp empty_context, do: %{generic_names: MapSet.new()}
end
