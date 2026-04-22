# Notes for Claude

## Build setup (from a fresh machine)

The project pins Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28 via `.tool-versions`.
Ubuntu's apt ships Elixir 1.14 / OTP 25, which is too old — do not use it.

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
