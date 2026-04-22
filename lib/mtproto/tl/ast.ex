defmodule MTProto.TL.AST do
  @moduledoc """
  Abstract syntax tree nodes for Telegram TL schema parsing.
  """

  defmodule Schema do
    @moduledoc false

    defstruct items: []
  end

  defmodule Section do
    @moduledoc false

    defstruct name: nil, line: nil
  end

  defmodule Definition do
    @moduledoc false

    defstruct name: nil,
              id: nil,
              kind: nil,
              section: nil,
              generics: [],
              params: [],
              result: nil,
              line: nil
  end

  defmodule Generic do
    @moduledoc false

    defstruct name: nil, kind: nil
  end

  defmodule Param do
    @moduledoc false

    defstruct name: nil, type: nil
  end

  defmodule Expr.Reference do
    @moduledoc false

    defstruct name: nil
  end

  defmodule Expr.Number do
    @moduledoc false

    defstruct value: nil
  end

  defmodule Expr.Special do
    @moduledoc false

    defstruct value: nil
  end

  defmodule Expr.Prefix do
    @moduledoc false

    defstruct operator: nil, expr: nil
  end

  defmodule Expr.Application do
    @moduledoc false

    defstruct callee: nil, args: [], syntax: nil
  end

  defmodule Expr.Group do
    @moduledoc false

    defstruct delimiter: nil, items: []
  end

  defmodule Expr.Repetition do
    @moduledoc false

    defstruct multiplier: nil, expr: nil
  end

  defmodule Expr.Conditional do
    @moduledoc false

    defstruct guard: nil, expr: nil
  end

  def definitions(%Schema{items: items}) do
    Enum.filter(items, &match?(%Definition{}, &1))
  end

  def sections(%Schema{items: items}) do
    Enum.filter(items, &match?(%Section{}, &1))
  end
end
