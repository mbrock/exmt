defmodule MTProto.TL.Schema do
  @moduledoc """
  Normalized TL schema representation.
  """

  defmodule Schema do
    @moduledoc false

    defstruct name: nil, definitions: []
  end

  defmodule Definition do
    @moduledoc false

    defstruct schema: nil,
              kind: nil,
              tl_name: nil,
              id: nil,
              generics: [],
              params: [],
              result_type: nil,
              line: nil
  end

  defmodule Generic do
    @moduledoc false

    defstruct name: nil, kind: nil
  end

  defmodule Param do
    @moduledoc false

    defstruct field: nil, tl_name: nil, type: nil
  end

  defmodule TypeExpr.Ref do
    @moduledoc false

    defstruct name: nil, segments: [], kind: nil, boxing: nil
  end

  defmodule TypeExpr.Vector do
    @moduledoc false

    defstruct item_type: nil, boxing: nil
  end

  defmodule TypeExpr.Bang do
    @moduledoc false

    defstruct type: nil
  end

  defmodule TypeExpr.Bare do
    @moduledoc false

    defstruct type: nil
  end

  defmodule TypeExpr.Flag do
    @moduledoc false

    defstruct field: nil, tl_name: nil, bit: nil, type: nil
  end

  defmodule TypeExpr.Conditional do
    @moduledoc false

    defstruct guard: nil, type: nil
  end

  defmodule TypeExpr.Repetition do
    @moduledoc false

    defstruct multiplier: nil, type: nil
  end

  defmodule TypeExpr.Application do
    @moduledoc false

    defstruct callee: nil, args: [], syntax: nil
  end

  defmodule TypeExpr.Group do
    @moduledoc false

    defstruct delimiter: nil, items: []
  end

  defmodule TypeExpr.Number do
    @moduledoc false

    defstruct value: nil
  end

  defmodule TypeExpr.Special do
    @moduledoc false

    defstruct value: nil
  end
end
