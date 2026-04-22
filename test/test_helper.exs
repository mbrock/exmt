for pattern <- ["../test_support/**/*.ex", "../test_support/**/*.exs"],
    file <- Path.join(__DIR__, pattern) |> Path.wildcard() do
  Code.require_file(file)
end

ExUnit.start()
