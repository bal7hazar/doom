# doom_player

**Does**: the player's per-tic think function (`think`, the seed of
`P_PlayerThink`): turns a `ticcmd::TicCmd` into an attempted straight-line
move validated through `doom_physics::can_move`, and `apply_damage`
(saturating health, the seed of the damage/death path). `spawn` builds the
initial `PlayerState` from `doom_things`'s catalogue entry.

**Does not**: implement weapons, ammo, pickups, keys, or use-lines yet
(PLAN.md §3.1, task 4) — those are Phase 1 additions once the full
`ticcmd` button semantics and `doom_specials` (for use-lines) exist; it
does not rotate the player by `angle_turn` yet (movement is currently
along a single fixed axis, a placeholder until `bam`/`geom2d` angle-to-
vector conversion is wired in).

**Invariants**: `think` never moves the player through a blocking line
(delegates entirely to `doom_physics::can_move`, so this crate carries no
collision logic of its own); `apply_damage` never underflows — health
saturates at zero instead of panicking, and health is monotonically
non-increasing under repeated `apply_damage` calls with non-negative
amounts.
