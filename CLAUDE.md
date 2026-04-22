# Notes for Claude

## Build setup (from a fresh machine)

`.tool-versions` pins Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28 — the
preferred development toolchain. The project floor is `~> 1.14` and the full
test suite passes on Ubuntu 24.04's apt `elixir` / `erlang` packages
(Elixir 1.14 / OTP 25) too. Either works.

The dev-only `mix tl.fetch_telegram_schema` task calls `JSON.decode/1`, which
only exists on Elixir 1.18+. Warning is suppressed via
`@compile {:no_warn_undefined, {JSON, :decode, 1}}`; on 1.14 the task
compiles fine but will crash if run. The runtime path (schema loading,
decoding) has no JSON dependency.

### Install the toolchain with mise

```bash
# mise.run / the jdx site sometimes 503 — fetch the binary from mise.jdx.dev instead
curl -fsSL "https://mise.jdx.dev/mise-latest-linux-x64" -o /tmp/mise
chmod +x /tmp/mise && cp /tmp/mise /usr/local/bin/mise

eval "$(mise activate bash)"
mise install   # reads .tool-versions, fetches precompiled OTP + Elixir from builds.hex.pm
```

If `mise install` fails with `HTTP status server error (503 Service Unavailable)`
for `builds.hex.pm`, it is transient. Wait for it to recover, then retry:

```bash
until curl -fsI https://builds.hex.pm/installs/rebar.csv >/dev/null 2>&1; do sleep 2; done
mise install
```

### Required env vars

Elixir 1.19 on this OTP warns about latin1 encoding and misbehaves without UTF-8.
Always export before running `mix`:

```bash
export LANG=C.UTF-8 LC_ALL=C.UTF-8 ELIXIR_ERL_OPTIONS="+fnu"
```

### Bootstrap mix tooling

`mix local.hex` / `mix local.rebar` hit `builds.hex.pm` and also 503 intermittently.
Same fix — wait and retry:

```bash
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
```

## Building

Library (root):

```bash
mix deps.get
mix compile --warnings-as-errors
```

CLI escript (`cli/`):

```bash
cd cli
mix deps.get
mix escript.build     # produces ./exmt
```

Full precommit checks exist in both projects:

```bash
mix precommit          # root: compile, deps.unlock check, format, test
cd cli && mix precommit
```
