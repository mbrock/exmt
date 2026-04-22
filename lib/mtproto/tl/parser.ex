defmodule MTProto.TL.Parser do
  @moduledoc """
  Pure parser for Telegram TL schema files.

  The parser keeps the output close to the source grammar so later codegen can
  decide how much semantic interpretation to layer on top.
  """

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
  alias MTProto.TL.AST.Schema
  alias MTProto.TL.AST.Section

  @punctuation ~w({ } [ ] < > : ; ? ! % # *)
  @prefix_operators ~w(! %)

  @spec parse(binary()) :: {:ok, Schema.t()} | {:error, map()}
  def parse(source) when is_binary(source) do
    source
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, nil, []}, fn {line, line_number},
                                            {:ok, section, items} ->
      case parse_line(line, line_number, section) do
        {:skip, section} ->
          {:cont, {:ok, section, items}}

        {:ok, section, item} ->
          {:cont, {:ok, section, [item | items]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, _section, items} -> {:ok, %Schema{items: Enum.reverse(items)}}
      {:error, error} -> {:error, error}
    end
  end

  @spec parse_file(Path.t()) :: {:ok, Schema.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, source} <- File.read(path) do
      parse(source)
    end
  end

  @spec parse_definition(binary(), keyword()) ::
          {:ok, Definition.t()} | {:error, map()}
  def parse_definition(line, opts \\ []) when is_binary(line) do
    line_number = Keyword.get(opts, :line, 1)
    section = Keyword.get(opts, :section)
    trimmed = String.trim(line)

    with {:ok, definition} <-
           do_parse_definition(trimmed, line_number, section) do
      {:ok, definition}
    else
      {:error, reason} ->
        {:error, %{line: line_number, source: trimmed, reason: reason}}
    end
  end

  defp parse_line(line, line_number, section) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:skip, section}

      String.starts_with?(trimmed, "//") ->
        {:skip, section}

      section_marker?(trimmed) ->
        next_section = parse_section_name(trimmed)
        {:ok, next_section, %Section{name: next_section, line: line_number}}

      true ->
        case parse_definition(trimmed, line: line_number, section: section) do
          {:ok, definition} -> {:ok, section, definition}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp do_parse_definition(line, line_number, section) do
    tokens = tokenize(line)

    with {:ok, name, tokens} <- take_identifier(tokens),
         {:ok, id, tokens} <- maybe_take_constructor_id(tokens),
         {:ok, generics, tokens} <- parse_generics(tokens, []),
         {:ok, params, ["=" | tokens]} <- parse_params(tokens, []),
         {:ok, result, [";"]} <- parse_expr(tokens, application: true) do
      {:ok,
       %Definition{
         name: name,
         id: id,
         kind: definition_kind(section),
         section: section,
         generics: generics,
         params: params,
         result: result,
         line: line_number
       }}
    else
      {:ok, _result, rest} ->
        {:error, {:unexpected_tokens, rest}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_definition, other}}
    end
  end

  defp parse_generics(["{" | rest], generics) do
    with {:ok, name, [":" | rest]} <- take_identifier(rest),
         {:ok, kind, ["}" | rest]} <- parse_expr(rest, application: false) do
      parse_generics(rest, [%Generic{name: name, kind: kind} | generics])
    end
  end

  defp parse_generics(tokens, generics),
    do: {:ok, Enum.reverse(generics), tokens}

  defp parse_params(["=" | _] = tokens, params),
    do: {:ok, Enum.reverse(params), tokens}

  defp parse_params([name, ":" | rest], params) do
    if identifier_token?(name) do
      with {:ok, type, rest} <- parse_expr(rest, application: false) do
        parse_params(rest, [%Param{name: name, type: type} | params])
      end
    else
      {:error, {:expected_identifier, name}}
    end
  end

  defp parse_params(tokens, params) do
    with {:ok, type, rest} <- parse_expr(tokens, application: false) do
      parse_params(rest, [%Param{type: type} | params])
    end
  end

  defp parse_expr(tokens, opts) do
    application? = Keyword.get(opts, :application, false)

    with {:ok, expr, rest} <- parse_term(tokens) do
      if application? do
        parse_juxtaposition(expr, rest, [])
      else
        {:ok, expr, rest}
      end
    end
  end

  defp parse_juxtaposition(callee, tokens, args) do
    if start_of_primary?(tokens) do
      with {:ok, arg, rest} <- parse_term(tokens) do
        parse_juxtaposition(callee, rest, [arg | args])
      end
    else
      case Enum.reverse(args) do
        [] ->
          {:ok, callee, tokens}

        parsed_args ->
          {:ok,
           %Application{
             callee: callee,
             args: parsed_args,
             syntax: :juxtaposition
           }, tokens}
      end
    end
  end

  defp parse_term(tokens) do
    with {:ok, expr, rest} <- parse_primary(tokens),
         {:ok, expr, rest} <- maybe_parse_angle_application(expr, rest),
         {:ok, expr, rest} <- maybe_parse_repetition(expr, rest),
         {:ok, expr, rest} <- maybe_parse_conditional(expr, rest) do
      {:ok, expr, rest}
    end
  end

  defp parse_primary([operator | rest]) when operator in @prefix_operators do
    with {:ok, expr, rest} <- parse_primary(rest) do
      {:ok, %Prefix{operator: String.to_atom(operator), expr: expr}, rest}
    end
  end

  defp parse_primary(["#" | rest]), do: {:ok, %Special{value: "#"}, rest}
  defp parse_primary(["?" | rest]), do: {:ok, %Special{value: "?"}, rest}

  defp parse_primary(["[" | rest]) do
    with {:ok, items, ["]" | rest]} <- parse_group_items(rest, []) do
      {:ok, %Group{delimiter: :square, items: items}, rest}
    end
  end

  defp parse_primary([token | rest]) do
    if identifier_token?(token) do
      expr =
        if decimal_number?(token) do
          %Number{value: String.to_integer(token)}
        else
          %Reference{name: token}
        end

      {:ok, expr, rest}
    else
      {:error, {:expected_expression, [token | rest]}}
    end
  end

  defp parse_primary(tokens), do: {:error, {:expected_expression, tokens}}

  defp maybe_parse_angle_application(callee, ["<" | rest]) do
    with {:ok, args, [">" | rest]} <- parse_angle_args(rest, []) do
      {:ok, %Application{callee: callee, args: args, syntax: :angle}, rest}
    end
  end

  defp maybe_parse_angle_application(expr, tokens), do: {:ok, expr, tokens}

  defp maybe_parse_repetition(multiplier, ["*" | rest]) do
    with {:ok, expr, rest} <- parse_primary(rest) do
      {:ok, %Repetition{multiplier: multiplier, expr: expr}, rest}
    end
  end

  defp maybe_parse_repetition(expr, tokens), do: {:ok, expr, tokens}

  defp maybe_parse_conditional(guard, ["?" | rest]) do
    with {:ok, expr, rest} <- parse_expr(rest, application: false) do
      {:ok, %Conditional{guard: guard, expr: expr}, rest}
    end
  end

  defp maybe_parse_conditional(expr, tokens), do: {:ok, expr, tokens}

  defp parse_group_items(["]" | _] = tokens, items),
    do: {:ok, Enum.reverse(items), tokens}

  defp parse_group_items(tokens, items) do
    with {:ok, expr, rest} <- parse_expr(tokens, application: false) do
      parse_group_items(rest, [expr | items])
    end
  end

  defp parse_angle_args([">" | _] = tokens, args),
    do: {:ok, Enum.reverse(args), tokens}

  defp parse_angle_args(tokens, args) do
    with {:ok, expr, rest} <- parse_expr(tokens, application: false) do
      parse_angle_args(rest, [expr | args])
    end
  end

  defp maybe_take_constructor_id(["#", token | rest]) do
    if hex_number?(token) do
      {:ok, String.to_integer(token, 16), rest}
    else
      {:error, {:expected_hex_constructor_id, token}}
    end
  end

  defp maybe_take_constructor_id(tokens), do: {:ok, nil, tokens}

  defp take_identifier([token | rest]) do
    if identifier_token?(token) do
      {:ok, token, rest}
    else
      {:error, {:expected_identifier, [token | rest]}}
    end
  end

  defp take_identifier(tokens), do: {:error, {:expected_identifier, tokens}}

  defp tokenize(line), do: tokenize(line, [])

  defp tokenize(<<>>, tokens), do: Enum.reverse(tokens)

  defp tokenize(<<char, rest::binary>>, tokens) when char in [?\s, ?\t] do
    tokenize(rest, tokens)
  end

  defp tokenize(<<char, rest::binary>>, tokens)
       when char in [?{, ?}, ?[, ?], ?<, ?>, ?:, ?;, ??, ?!, ?%, ?#, ?*] do
    tokenize(rest, [<<char>> | tokens])
  end

  defp tokenize(binary, tokens) do
    {token, rest} = take_token(binary, "")
    tokenize(rest, [token | tokens])
  end

  defp take_token(<<>>, acc), do: {acc, <<>>}

  defp take_token(<<char, _rest::binary>> = binary, acc)
       when char in [
              ?\s,
              ?\t,
              ?{,
              ?},
              ?[,
              ?],
              ?<,
              ?>,
              ?:,
              ?;,
              ??,
              ?!,
              ?%,
              ?#,
              ?*
            ] do
    {acc, binary}
  end

  defp take_token(<<char, rest::binary>>, acc),
    do: take_token(rest, acc <> <<char>>)

  defp start_of_primary?([token | _]) do
    token in ["[", "#", "?", "!", "%"] or identifier_token?(token)
  end

  defp start_of_primary?(_), do: false

  defp section_marker?(line),
    do: String.starts_with?(line, "---") and String.ends_with?(line, "---")

  defp parse_section_name(line) do
    line
    |> String.trim_leading("---")
    |> String.trim_trailing("---")
    |> String.to_atom()
  end

  defp definition_kind(:functions), do: :function
  defp definition_kind(_), do: :constructor

  defp identifier_token?(token),
    do: is_binary(token) and token not in @punctuation

  defp decimal_number?(token), do: String.match?(token, ~r/^\d+$/)
  defp hex_number?(token), do: String.match?(token, ~r/^[0-9a-fA-F]+$/)
end
