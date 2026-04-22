# exmt

Experimental Telegram/MTProto client work in Elixir.

The repo has two parts:

- `exmt`: the library, with the public modules under the `MTProto` namespace
- `cli/`: a separate Mix project that builds the `exmt` command-line tool

The design goal is a small sans-IO core with thin runtime adapters around it.

## Status

Current working pieces include:

- pure MTProto abridged transport framing
- pure plain and encrypted MTProto packet codecs
- pure auth-key exchange
- pure MTProto session state and encrypted request tracking
- Telegram API wrapping and schema-driven result decoding
- official Telegram schema vendored as an Elixir term at `priv/tl/telegram_api.exs`
- a working CLI that can:
  - `get-config`
  - `auth send-code`
  - `auth sign-in`
  - `whoami`
  - `follow`

`follow` currently persists Telegram updates state and polls `updates.getDifference`.

This is still exploratory client work, not a production-hardened Telegram client.

## Layout

```text
lib/mtproto/**              # MTProto core and Telegram-specific library layers
priv/tl/**                  # vendored TL / schema inputs
cli/                        # separate CLI Mix project
  lib/exmt/cli/**           # commands and CLI helpers
```

Important modules:

- `MTProto.Client`: MTProto process layer with durable session persistence hooks
- `MTProto.Telegram.Client`: Telegram API layer on top of MTProto
- `MTProto.Telegram.Result`: schema-driven Telegram result decoding
- `MTProto.Telegram.UpdateState` and `MTProto.Telegram.Updates`: durable updates state and pure difference handling

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP compatible with the repo's `.tool-versions`

## Development

Run the root checks:

```bash
mix precommit
```

Run the CLI checks:

```bash
cd cli
mix precommit
```

Build the CLI escript:

```bash
cd cli
mix escript.build
```

## Environment

The CLI reads:

- `TDLIB_API_ID` or `TELEGRAM_API_ID`
- `TDLIB_API_HASH` or `TELEGRAM_API_HASH`

`api_hash` is needed for auth commands. `api_id` is needed for Telegram API requests generally.

## Quick Start

Fetch config:

```bash
cd cli
mix escript.build
./exmt get-config --timeout 60000
```

Send a login code:

```bash
cd cli
./exmt auth send-code +15551234567
```

Sign in with the returned `phone_code_hash`:

```bash
cd cli
./exmt auth sign-in +15551234567 <PHONE_CODE_HASH> <PHONE_CODE>
```

Fetch the current logged-in user:

```bash
cd cli
./exmt whoami --timeout 60000
```

Tail Telegram updates:

```bash
cd cli
./exmt follow --duration 60000 --poll-interval 1000 --timeout 60000
```

By default the CLI stores:

- session data in `.exmt/session.term`
- Telegram updates state in `.exmt/session.updates.term`

## Schema

Telegram result decoding uses the official schema snapshot, vendored as a
pretty-printed Elixir term at `priv/tl/telegram_api.exs` and compiled in via
`@external_resource` (see `MTProto.TL.VendoredSchema`). There is no runtime
JSON dependency.

Refresh it with:

```bash
mix tl.fetch_telegram_schema
```

There is still TL tooling in the repo for other schema/codegen work, but the
Telegram runtime decode path now prefers the vendored snapshot.

## Project Direction

The intended layering is:

1. pure MTProto transport, crypto, auth, and session logic
2. a narrow Telegram layer for API envelopes and decoding
3. a separate CLI that owns env lookup, session file policy, and developer-facing commands

That split is deliberate: the library should stay reusable, while the CLI remains free to be pragmatic and stateful.
