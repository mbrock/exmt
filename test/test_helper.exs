for pattern <- ["../test_support/**/*.ex", "../test_support/**/*.exs"],
    file <- Path.join(__DIR__, pattern) |> Path.wildcard() do
  Code.require_file(file)
end

# Warm the schema registry so the first test to touch the TL decoder does not
# pay the cold-load cost under assert_receive's default timeout.
MTProto.TL.Runtime.decode(<<0xB5, 0x75, 0x72, 0x99>>)

ExUnit.start()
