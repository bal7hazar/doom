# ticcmd

**Does**: encodes/decodes a single player input command (`TicCmd { forward,
side, angle_turn, buttons }`, matching the fields of Doom's `ticcmd_t`)
to and from one `felt252` (`pack`/`unpack`), so that a journal of inputs is
a compact array of felts suitable for hashing (`state_hash`) and for
`segment`'s per-tic replay loop.

**Does not**: pack multiple tics into a single felt yet — PLAN.md §2
anticipates a denser "7 tics per felt" production encoding once the exact
field widths are locked at G0; this crate ships the one-command building
block that encoding will be built on, and the felt budget it needs
(bits per field) is exactly what is validated here.

**Invariants**: `unpack(pack(cmd)) == cmd` for every `cmd` whose fields are
within Doom's native ranges (`forward`, `side` ∈ [-128, 127]; `angle_turn`
∈ [-32768, 32767]; `buttons` ∈ [0, 255]); `pack` panics rather than
silently truncating when a field is out of range (never a poisoned value
enters a hash or a proof, per the zero-panic-in-*production*-but-loud-in-
tests policy, RISKS.md R4).
