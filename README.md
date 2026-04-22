# exmt

Experimental MTProto client work in Elixir.

The public modules currently live under the `MTProto` namespace even though the Mix app is named `:exmt`.

Current scope:

- pure abridged transport framing
- pure unencrypted MTProto message envelope codec
- pure auth bootstrap state machine for `req_pq_multi -> resPQ`
- tests pinned to Telegram's official auth-key generation sample

The intended shape is a small sans-IO core first, with any actual socket/process layer added later as a thin adapter around emitted effects like `{:send_bytes, binary}`.
