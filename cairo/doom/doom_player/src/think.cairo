// SPDX-License-Identifier: GPL-2.0-only
//! One tic of the player — linuxdoom-1.10's `p_user.c`: `P_PlayerThink`,
//! `P_MovePlayer`, `P_Thrust`, `P_CalcHeight`, `P_DeathThink` and
//! `P_UseLines`.
//!
//! `P_PlayerThink` only sets momentum; the move itself is
//! `doom_physics::xy_movement`, which `doom_game` runs in the thinker pass
//! **after** every `player_think`, exactly as `P_Ticker` does.

use bam::{ANG90, Angle, point_to_angle2, sin_cos};
use doom_map::NO_SECTOR;
use doom_physics::maputl::{line_hp, line_meta, line_opening, rd};
use doom_physics::spawn::state_entry;
use doom_physics::{
    Intercept, MF_JUSTATTACKED, Mobj, NO_MOBJ, ThingGrid, has, path_traverse, without,
};
use fixed::{BIAS, Fixed};
use geom2d::{Point, SIDE_BACK, point_side_alone};
use prng::Prng;
use super::env::{Env, PlayerEvent};
use super::inter::damage_player;
use super::num::{dec, div32, fine_of, inc, rd32};
use super::state::{
    BT_CHANGE, BT_USE, BT_WEAPONMASK, BT_WEAPONSHIFT_NZ, HALF_VIEWHEIGHT, MAXBOB, MOVE_UNIT,
    PST_DEAD, PST_LIVE, Player, USERANGE, VIEWHEIGHT, WEAPON_OF_BUTTON, WP_CHAINSAW, WP_FIST,
    WP_NOCHANGE, owns,
};
use super::weapon::{S_PLAY, move_psprites};

/// `ANG5` = `ANG90 / 18`, the angle a dying player turns toward its killer.
pub const ANG5: u32 = 0x40000000 / 18;
/// `-ANG5` as an unsigned `angle_t`, folded here rather than at each tic.
const NEG_ANG5: u32 = 0xFFFFFFFF - ANG5 + 1;
/// `S_PLAY_RUN1`.
pub const S_PLAY_RUN1: u32 = 59;
/// One past `S_PLAY_RUN4`, written out so the comparison carries no `+`.
const S_PLAY_RUN_END: u32 = 63;
/// `0xc800 / 512`: the forward move a chainsaw hit forces for one tic.
pub const SAW_FORWARD: i64 = 100;

/// `P_PlayerThink(player)` for one already-decoded ticcmd word (D15).
///
/// `sector_damage` and `sector_secret` are the answer
/// `doom_specials::player_in_special_sector` gave for the sector the player
/// stands in — the caller computes them *before* this call, because Doom
/// reads the sector the player was in when the tic began (its mobj has not
/// moved yet). [`super::tic::player_tic`] does that wiring;
/// `doom_game` may do it itself.
///
/// A `BT_USE` press that finds a special line is reported as
/// `PlayerEvent::Use`; a shot as `PlayerEvent::Shot`.
pub fn player_think(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    word: felt252,
    sector_damage: u32,
    sector_secret: bool,
    ref events: Array<PlayerEvent>,
) {
    let cmd = ticcmd::decode(word);
    let mut forward = cmd.forward;
    let mut side = cmd.side;
    let mut turn = cmd.angle_turn;
    // "chain saw run forward": a hit drags the player after its victim.
    if has(mo.flags, MF_JUSTATTACKED) {
        turn = 0;
        forward = SAW_FORWARD;
        side = 0;
        mo.flags = without(mo.flags, MF_JUSTATTACKED);
    }

    if p.playerstate == PST_DEAD {
        death_think(env, ref g, ref rng, ref p, ref mo, ref events);
        return;
    }

    // Reactiontime is used to prevent movement for a bit after a teleport.
    if mo.reaction_time != 0 {
        mo.reaction_time = dec(mo.reaction_time);
    } else {
        move_player(env, ref p, ref mo, forward, side, turn);
    }
    calc_height(ref p, @mo, env.tic);

    // P_PlayerInSpecialSector, decided by the caller.
    if sector_secret {
        p.secretcount = inc(p.secretcount);
    }
    if sector_damage != 0 {
        damage_player(
            env, ref g, ref rng, ref p, ref mo, ref events, NO_MOBJ, NO_MOBJ, sector_damage, false,
        );
    }

    buttons(env, ref g, ref rng, ref p, ref mo, ref events);
    counters(ref p);
}

/// The `BT_CHANGE` / `BT_USE` / `P_MovePsprites` tail of `P_PlayerThink`.
///
/// Split out of [`player_think`] so that neither function keeps its live set
/// alive across more than ~150 Sierra statements: past that,
/// `universal-sierra-compiler` cannot encode a jump offset (`Offset
/// overflow`) under the `inlining-strategy = "avoid"` that `cairo-coverage`
/// requires. It costs one call boundary a tic.
fn buttons(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    if (env.buttons & BT_CHANGE) != 0 {
        change_weapon(ref p, env.buttons);
    }
    if (env.buttons & BT_USE) != 0 {
        if !p.usedown {
            use_lines(env, ref g, @mo, ref events);
            p.usedown = true;
        }
    } else {
        p.usedown = false;
    }
    move_psprites(env, ref g, ref rng, ref p, ref mo, ref events);
}

/// `P_PlayerThink`'s counters. `pw_strength` is the only power reachable on
/// E1M1 at skill 2, and it counts up for ever (vanilla reads it for the
/// berserk palette only).
fn counters(ref p: Player) {
    if p.strength != 0 {
        p.strength = inc(p.strength);
    }
    if p.damagecount != 0 {
        p.damagecount = dec(p.damagecount);
    }
    if p.bonuscount != 0 {
        p.bonuscount = dec(p.bonuscount);
    }
}

// ---------------------------------------------------------------------------
// P_MovePlayer / P_Thrust
// ---------------------------------------------------------------------------

/// `P_MovePlayer`: turn, then thrust forward and sideways while on ground.
pub fn move_player(env: Env, ref p: Player, ref mo: Mobj, forward: i64, side: i64, turn: i64) {
    // `angle += cmd->angleturn << 16`, summed in the field and reduced once
    // (S1 §7); `+ 2^32` keeps the felt non-negative for `bam::reduce`.
    let t: felt252 = turn.into();
    mo.angle = bam::reduce(mo.angle.into() + t * 65536 + 0x100000000);
    let onground = fixed::le(mo.z, mo.floorz);
    if forward != 0 && onground {
        thrust(ref mo, mo.angle, forward);
    }
    if side != 0 && onground {
        thrust(ref mo, bam::sub(mo.angle, ANG90), side);
    }
    if (forward != 0 || side != 0) && mo.state == S_PLAY {
        let (tics, _) = state_entry(env.states, S_PLAY_RUN1);
        mo.state = S_PLAY_RUN1;
        mo.tics = tics;
    }
}

/// `P_Thrust(player, angle, move * 2048)`.
pub fn thrust(ref mo: Mobj, angle: Angle, move: i64) {
    let raw: felt252 = move.into();
    let m = fixed::from_raw(raw * MOVE_UNIT);
    let (s, c) = sin_cos(angle);
    mo.momx = fixed::add(mo.momx, fixed::mul(m, c));
    mo.momy = fixed::add(mo.momy, fixed::mul(m, s));
}

// ---------------------------------------------------------------------------
// P_CalcHeight
// ---------------------------------------------------------------------------

/// `P_CalcHeight`: the bob amplitude, the view height's spring, and `viewz`.
///
/// Vanilla's off-ground branch computes `viewz` twice and throws the first
/// (clamped) value away; the second assignment is not clamped. That is
/// reproduced here — `doom_game`'s renderer sees what Doom's does.
pub fn calc_height(ref p: Player, mo: @Mobj, tic: u32) {
    // bob = (momx^2 + momy^2) >> 2, capped at MAXBOB.
    let sq = fixed::add(fixed::mul(*mo.momx, *mo.momx), fixed::mul(*mo.momy, *mo.momy));
    let four: NonZero<u128> = 4;
    let (mag, _) = DivRem::div_rem(fixed::to_u128(sq.enc - BIAS), four);
    let quarter: felt252 = mag.into();
    p
        .bob =
            if fixed::felt_ge_narrow(quarter, MAXBOB + 1) {
                Fixed { enc: BIAS + MAXBOB }
            } else {
                Fixed { enc: BIAS + quarter }
            };

    let onground = fixed::le(*mo.z, *mo.floorz);
    if p.cheats != 0 || !onground {
        p.viewz = fixed::add(*mo.z, p.viewheight);
        return;
    }

    let idx = fine_of(409, tic);
    let two: NonZero<u128> = 2;
    let (half, _) = DivRem::div_rem(fixed::to_u128(p.bob.enc - BIAS), two);
    let bob = fixed::mul(Fixed { enc: BIAS + half.into() }, bam::finesine(idx));

    if p.playerstate == PST_LIVE {
        spring(ref p);
    }

    p.viewz = fixed::add(fixed::add(*mo.z, p.viewheight), bob);
    let head = Fixed { enc: *mo.ceilingz.enc - 4 * 65536 };
    if fixed::gt(p.viewz, head) {
        p.viewz = head;
    }
}

/// `P_CalcHeight`'s view-height spring: it climbs back to `VIEWHEIGHT` after
/// a hard landing, never falls below half of it, and accelerates by
/// `FRACUNIT/4` a tic while it is moving.
fn spring(ref p: Player) {
    p.viewheight = fixed::add(p.viewheight, p.deltaviewheight);
    let top = Fixed { enc: BIAS + VIEWHEIGHT };
    if fixed::gt(p.viewheight, top) {
        p.viewheight = top;
        p.deltaviewheight = fixed::ZERO;
    }
    let floor = Fixed { enc: BIAS + HALF_VIEWHEIGHT };
    if fixed::lt(p.viewheight, floor) {
        p.viewheight = floor;
        if fixed::le(p.deltaviewheight, fixed::ZERO) {
            p.deltaviewheight = Fixed { enc: BIAS + 1 };
        }
    }
    if p.deltaviewheight != fixed::ZERO {
        p.deltaviewheight = Fixed { enc: p.deltaviewheight.enc + 16384 };
        if p.deltaviewheight == fixed::ZERO {
            p.deltaviewheight = Fixed { enc: BIAS + 1 };
        }
    }
}

// ---------------------------------------------------------------------------
// P_DeathThink
// ---------------------------------------------------------------------------

/// `P_DeathThink`: the camera sinks to six units and turns toward the killer.
///
/// `BT_USE` starts `PST_REBORN` in vanilla; a proven single-player run has no
/// respawn — the segment ends with D14's `status = 1 (DEAD)` — so the press
/// is ignored here and `doom_game` reads [`Player::playerstate`].
pub fn death_think(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    move_psprites(env, ref g, ref rng, ref p, ref mo, ref events);
    let six = Fixed { enc: BIAS + 6 * 65536 };
    if fixed::gt(p.viewheight, six) {
        p.viewheight = Fixed { enc: p.viewheight.enc - 65536 };
    }
    if fixed::lt(p.viewheight, six) {
        p.viewheight = six;
    }
    p.deltaviewheight = fixed::ZERO;
    calc_height(ref p, @mo, env.tic);

    let target = if p.attacker != NO_MOBJ && p.attacker != p.mo {
        env.mobjs.get(p.attacker)
    } else {
        Option::None
    };
    match target {
        Option::Some(b) => {
            let t = b.unbox();
            let facing = point_to_angle2(mo.x, mo.y, *t.x, *t.y);
            let delta = bam::sub(facing, mo.angle);
            if delta < ANG5 || delta > NEG_ANG5 {
                mo.angle = facing;
                if p.damagecount != 0 {
                    p.damagecount = dec(p.damagecount);
                }
            } else if delta < 0x80000000 {
                mo.angle = bam::add(mo.angle, ANG5);
            } else {
                mo.angle = bam::sub(mo.angle, ANG5);
            }
        },
        Option::None => { if p.damagecount != 0 {
            p.damagecount = dec(p.damagecount);
        } },
    }
}

// ---------------------------------------------------------------------------
// The weapon-change buttons
// ---------------------------------------------------------------------------

/// The `BT_CHANGE` half of `P_PlayerThink`.
///
/// Doom's "fist means chainsaw when you own one and are not berserk with the
/// saw already up" shortcut is kept; the shareware/commercial gates are not
/// (one game mode, one roster).
pub fn change_weapon(ref p: Player, buttons: u32) {
    let requested = div32(buttons & BT_WEAPONMASK, BT_WEAPONSHIFT_NZ);
    let mut new = rd32(WEAPON_OF_BUTTON.span(), requested);
    if new == WP_FIST
        && owns(@p, WP_CHAINSAW)
        && !(p.ready_weapon == WP_CHAINSAW && p.strength != 0) {
        new = WP_CHAINSAW;
    }
    if new != WP_NOCHANGE && owns(@p, new) && new != p.ready_weapon {
        p.pending_weapon = new;
    }
}

// ---------------------------------------------------------------------------
// P_UseLines
// ---------------------------------------------------------------------------

/// `P_UseLines` + `PTR_UseTraverse`: the `USERANGE` trace in front of the
/// player, stopping at the first special line (reported as
/// `PlayerEvent::Use`) or at the first closed opening.
///
/// The trace is `doom_physics`' — `path_traverse` with `PT_ADDLINES`, whose
/// intercepts already arrive nearest-first. Using the collector rather than
/// a `Traverser` implementation is deliberate: a second monomorphisation of
/// the generic `traverse` would cost this crate its whole bytecode budget
/// (S1 §5.9, D4: 60–77 words per monomorphisation, on a function that is
/// ~3 600 Sierra statements in `doom_physics`).
pub fn use_lines(env: Env, ref g: ThingGrid, mo: @Mobj, ref events: Array<PlayerEvent>) {
    let w = env.world.unbox();
    let p1 = Point { x: *mo.x, y: *mo.y };
    let (s, c) = sin_cos(*mo.angle);
    let range = Fixed { enc: BIAS + USERANGE };
    let p2 = Point {
        x: fixed::add(p1.x, fixed::mul(range, c)), y: fixed::add(p1.y, fixed::mul(range, s)),
    };
    let hits = path_traverse(w, env.mobjs, ref g, p1, p2, false, env.me).span();
    match used_line(w, hits, p1) {
        Option::Some(u) => { events.append(PlayerEvent::Use(u)); },
        Option::None => {},
    }
}

/// `PTR_UseTraverse`: the first special line the already-sorted crossings
/// reach, or `None` if a wall or a closed opening stops the trace first.
///
/// Split out of [`use_lines`] so that the loop's return is two felts and an
/// option tag rather than the caller's whole live set (S7 §8 rules 2 and 4),
/// and iterated by `pop_front` so that no read of the span can panic.
fn used_line(w: doom_physics::World, mut hits: Span<Intercept>, p1: Point) -> Option<(u32, u8)> {
    let mut out: Option<(u32, u8)> = Option::None;
    while let Option::Some(b) = hits.pop_front() {
        let it = *b;
        if !it.is_line {
            continue;
        }
        let meta = line_meta(rd(w.map.l_packed, it.id));
        if meta.special == 0 {
            // Not a special line: keep going unless it is a wall.
            if meta.back == NO_SECTOR || meta.front == NO_SECTOR {
                break;
            }
            let open = line_opening(w.floor, w.ceil, meta.front, meta.back);
            if fixed::le(open.top, open.bottom) {
                break; // "can't use through a wall"
            }
            continue;
        }
        let hp = line_hp(w.map.l_ab, w.map.l_bb, w.map.l_cb, it.id);
        let side: u8 = if point_side_alone(hp, p1) == SIDE_BACK {
            1
        } else {
            0
        };
        out = Option::Some((it.id, side));
        break; // "can't use for more than one special line in a row"
    }
    out
}

/// `P_XYMovement`'s last act on a player that stopped: a walking frame goes
/// back to standing. `doom_physics::xy_movement` reports
/// `XyOutcome::Stopped` rather than reaching into the state machine, so
/// `doom_game` calls this when it sees one.
pub fn player_stopped(env: Env, ref mo: Mobj) {
    if mo.state >= S_PLAY_RUN1 && mo.state < S_PLAY_RUN_END {
        let (tics, _) = state_entry(env.states, S_PLAY);
        mo.state = S_PLAY;
        mo.tics = tics;
    }
}

/// `onground` (`p_user.c`'s file-static), for the tests and `doom_game`.
pub fn onground(mo: @Mobj) -> bool {
    fixed::le(*mo.z, *mo.floorz)
}
