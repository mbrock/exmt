defmodule MTProto.Telegram.API.Namespaces do
  @moduledoc false

  alias MTProto.Telegram.Schema

  @grouped_methods Schema.available_methods()
                   |> Enum.filter(&String.contains?(&1, "."))
                   |> Enum.sort()
                   |> Enum.group_by(fn method ->
                     method
                     |> String.split(".")
                     |> hd()
                   end)

  defmacro __using__(_opts) do
    modules =
      for {namespace, methods} <- @grouped_methods do
        module_name =
          Module.concat(MTProto.Telegram.API, Macro.camelize(namespace))

        functions =
          for method <- methods do
            function_name =
              method
              |> String.split(".")
              |> List.last()
              |> String.to_atom()

            quote do
              def unquote(function_name)(opts \\ []) when is_list(opts) do
                {unquote(method), opts}
              end
            end
          end

        quote do
          defmodule unquote(module_name) do
            @moduledoc false

            unquote_splicing(functions)
          end
        end
      end

    quote do
      (unquote_splicing(modules))
    end
  end
end
