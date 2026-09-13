// SPDX-License-Identifier: GPL-2.0-only
//! One tic of the player — linuxdoom-1.10's `p_user.c`: `P_PlayerThink`,
//! `P_MovePlayer`, `P_Thrust`, `P_CalcHeight`, `P_DeathThink` and
//! `P_UseLines`.
//!
//! `P_PlayerThink` only sets momentum; the move itself is
//! `doom_physics::xy_movement`, which `doom_game` runs in the thinker pass
//! **after** every `player_think`, exactly as `P_Ticker` does.
//!
//! Like `super::weapon`, the whole inside of the tic works on
//! `Box<Env>`/`Box<Player>`/`Box<Mobj>` (S7 §8 rule 3, `env::enter`): the
//! public functions box once and each internal step rebuilds the record it
//! writes exactly once, so a tic pays one `into_box` per record it changes
//! instead of 63 felts at every one of its eight call boundaries.

use bam::{ANG90, Angle, point_to_angle2, sin_cos};
use doom_map::NO_SECTOR;
use doom_physics::maputl::{line_hp, line_meta, line_opening, rd};
use doom_physics::spawn::state_entry;
use doom_physics::{
    Intercept, MF_JUSTATTACKED, Mobj, NO_MOBJ, ThingGrid, World, has, path_traverse, without,
};
use fixed::{BIAS, Fixed};
use geom2d::{Point, SIDE_BACK, point_side_alone};
use prng::Prng;
use super::env::{Env, PlayerEvent, enter, leave};
use super::inter::damage_player_in;
use super::num::{dec, div32, fine_of, inc, rd32};
use super::state::{
    BT_CHANGE, BT_USE, BT_WEAPONMASK, BT_WEAPONSHIFT_NZ, HALF_VIEWHEIGHT, MAXBOB, MOVE_UNIT,
    PST_DEAD, PST_LIVE, Player, USERANGE, VIEWHEIGHT, WEAPON_OF_BUTTON, WP_CHAINSAW, WP_FIST,
    WP_NOCHANGE, owns,
};
use super::weapon::{S_PLAY, move_psprites_in};

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
/// Six units, where `P_DeathThink` parks the camera.
const SIX_UNITS: felt252 = 6 * 65536;

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
#[inline(always)]
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
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    think_in(cx, ref g, ref rng, ref bp, ref bm, word, sector_damage, sector_secret, ref events);
    leave(bp, bm, ref p, ref mo);
}

fn think_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
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
        mo = BoxTrait::new(Mobj { flags: without(mo.flags, MF_JUSTATTACKED), ..mo.unbox() });
    }

    if p.playerstate == PST_DEAD {
        death_think_in(env, ref g, ref rng, ref p, ref mo, ref events);
        return;
    }

    // Reactiontime is used to prevent movement for a bit after a teleport.
    if mo.reaction_time != 0 {
        mo = BoxTrait::new(Mobj { reaction_time: dec(mo.reaction_time), ..mo.unbox() });
    } else {
        move_player_in(env, ref mo, forward, side, turn);
    }
    calc_height_in(ref p, height_of(@mo.unbox()), env.tic);

    // P_PlayerInSpecialSector, decided by the caller.
    if sector_secret {
        p = BoxTrait::new(Player { secretcount: inc(p.secretcount), ..p.unbox() });
    }
    if sector_damage != 0 {
        damage_player_in(
            env, ref g, ref rng, ref p, ref mo, ref events, NO_MOBJ, NO_MOBJ, sector_damage, false,
        );
    }

    buttons(env, ref g, ref rng, ref p, ref mo, ref events);
    counters(ref p);
}

/// `P_PlayerThink`'s counters, which vanilla runs *after* `P_MovePsprites`
/// (`A_Punch` reads `pw_strength`). One rebuild of the record for the three.
/// `pw_strength` is the only power reachable on E1M1 at skill 2, and it
/// counts up for ever (vanilla reads it for the berserk palette only).
fn counters(ref p: Box<Player>) {
    let cur = p.unbox();
    if cur.strength == 0 && cur.damagecount == 0 && cur.bonuscount == 0 {
        return;
    }
    p =
        BoxTrait::new(
            Player {
                strength: if cur.strength != 0 {
                    inc(cur.strength)
                } else {
                    0
                },
                damagecount: if cur.damagecount != 0 {
                    dec(cur.damagecount)
                } else {
                    0
                },
                bonuscount: if cur.bonuscount != 0 {
                    dec(cur.bonuscount)
                } else {
                    0
                },
                ..cur,
            },
        );
}

/// The `BT_CHANGE` / `BT_USE` / `P_MovePsprites` tail of `P_PlayerThink`.
///
/// Split out of [`player_think`] so that neither function keeps its live set
/// alive across more than ~150 Sierra statements: past that,
/// `universal-sierra-compiler` cannot encode a jump offset (`Offset
/// overflow`) under the `inlining-strategy = "avoid"` that `cairo-coverage`
/// requires. It costs one call boundary a tic — of three felts now, not 79.
///
/// The weapon switch and the use latch are folded into a single rebuild of
/// the record: `P_PlayerThink` writes `pending_weapon` and `usedown` before
/// the trace and the psprites, and neither reads the other (S7 §8 rule 2).
fn buttons(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
) {
    let b = env.buttons;
    let cur = p.unbox();
    let pending = if (b & BT_CHANGE) != 0 {
        requested_weapon(@cur, b)
    } else {
        cur.pending_weapon
    };
    // A held `BT_USE` traces once: `usedown` ends the tic as the button is.
    let holding = (b & BT_USE) != 0;
    let trace = holding && !cur.usedown;
    if pending != cur.pending_weapon || holding != cur.usedown {
        p = BoxTrait::new(Player { pending_weapon: pending, usedown: holding, ..cur });
    }
    if trace {
        use_lines_in(env, ref g, mo, ref events);
    }
    move_psprites_in(env, ref g, ref rng, ref p, ref mo, ref events);
}

// ---------------------------------------------------------------------------
// P_MovePlayer / P_Thrust
// ---------------------------------------------------------------------------

/// `P_MovePlayer`: turn, then thrust forward and sideways while on ground.
#[inline(always)]
pub fn move_player(env: Env, ref p: Player, ref mo: Mobj, forward: i64, side: i64, turn: i64) {
    let (cx, bp, mut bm) = enter(env, @p, @mo);
    move_player_in(cx, ref bm, forward, side, turn);
    leave(bp, bm, ref p, ref mo);
}

/// [`move_player`] on the mobj alone: `P_MovePlayer` never reads or writes
/// the `Player` record (the `ref p` of the public form is there for the
/// caller's convenience and costs 36 felts each way).
fn move_player_in(env: Box<Env>, ref mo: Box<Mobj>, forward: i64, side: i64, turn: i64) {
    if forward == 0 && side == 0 && turn == 0 {
        // `P_MovePlayer` with an empty command is a no-op: the reduced angle
        // is the angle, no thrust is applied and the run frame needs one of
        // the two moves. Rebuilding the boxed mobj for it costs 54 steps.
        return;
    }
    let cur = mo.unbox();
    // `angle += cmd->angleturn << 16`, summed in the field and reduced once
    // (S1 §7); `+ 2^32` keeps the felt non-negative for `bam::reduce`.
    let t: felt252 = turn.into();
    let angle = bam::reduce(cur.angle.into() + t * 65536 + 0x100000000);
    let onground = fixed::le(cur.z, cur.floorz);
    let mut momx = cur.momx;
    let mut momy = cur.momy;
    if forward != 0 && onground {
        let (dx, dy) = thrust_of(angle, forward);
        momx = fixed::add(momx, dx);
        momy = fixed::add(momy, dy);
    }
    if side != 0 && onground {
        let (dx, dy) = thrust_of(bam::sub(angle, ANG90), side);
        momx = fixed::add(momx, dx);
        momy = fixed::add(momy, dy);
    }
    let (state, tics) = if (forward != 0 || side != 0) && cur.state == S_PLAY {
        let (t, _) = state_entry(env.states, S_PLAY_RUN1);
        (S_PLAY_RUN1, t)
    } else {
        (cur.state, cur.tics)
    };
    mo = BoxTrait::new(Mobj { angle, momx, momy, state, tics, ..cur });
}

/// `P_Thrust(player, angle, move * 2048)`.
pub fn thrust(ref mo: Mobj, angle: Angle, move: i64) {
    let (dx, dy) = thrust_of(angle, move);
    mo.momx = fixed::add(mo.momx, dx);
    mo.momy = fixed::add(mo.momy, dy);
}

/// The momentum `P_Thrust` adds, as a pair: the caller folds it into the one
/// rebuild of the mobj it does (a `ref Mobj` thrust would cost 27 felts each
/// way, twice a walking tic).
fn thrust_of(angle: Angle, move: i64) -> (Fixed, Fixed) {
    let raw: felt252 = move.into();
    let m = fixed::from_raw(raw * MOVE_UNIT);
    let (s, c) = sin_cos(angle);
    (fixed::mul(m, c), fixed::mul(m, s))
}

// ---------------------------------------------------------------------------
// P_CalcHeight
// ---------------------------------------------------------------------------

/// `P_CalcHeight`: the bob amplitude, the view height's spring, and `viewz`.
///
/// Vanilla's off-ground branch computes `viewz` twice and throws the first
/// (clamped) value away; the second assignment is not clamped. That is
/// reproduced here — `doom_game`'s renderer sees what Doom's does.
#[inline(always)]
pub fn calc_height(ref p: Player, mo: @Mobj, tic: u32) {
    let mut bp = BoxTrait::new(p);
    calc_height_in(ref bp, height_of(mo), tic);
    p = bp.unbox();
}

/// The five `Mobj` fields `P_CalcHeight` reads. Passing them rather than the
/// record keeps the call at five felts and saves boxing 27 (S7 §8 rule 3).
#[derive(Copy, Drop)]
struct Feet {
    momx: Fixed,
    momy: Fixed,
    z: Fixed,
    floorz: Fixed,
    ceilingz: Fixed,
}

#[inline(always)]
fn height_of(mo: @Mobj) -> Feet {
    Feet { momx: *mo.momx, momy: *mo.momy, z: *mo.z, floorz: *mo.floorz, ceilingz: *mo.ceilingz }
}

fn calc_height_in(ref p: Box<Player>, mo: Feet, tic: u32) {
    let cur = p.unbox();
    // bob = (momx^2 + momy^2) >> 2, capped at MAXBOB.
    let sq = fixed::add(fixed::mul(mo.momx, mo.momx), fixed::mul(mo.momy, mo.momy));
    let four: NonZero<u128> = 4;
    let (mag, _) = DivRem::div_rem(fixed::to_u128(sq.enc - BIAS), four);
    let quarter: felt252 = mag.into();
    let bob = if fixed::felt_ge_narrow(quarter, MAXBOB + 1) {
        Fixed { enc: BIAS + MAXBOB }
    } else {
        Fixed { enc: BIAS + quarter }
    };

    let onground = fixed::le(mo.z, mo.floorz);
    if cur.cheats != 0 || !onground {
        p = BoxTrait::new(Player { bob, viewz: fixed::add(mo.z, cur.viewheight), ..cur });
        return;
    }

    let idx = fine_of(409, tic);
    let two: NonZero<u128> = 2;
    let (half, _) = DivRem::div_rem(fixed::to_u128(bob.enc - BIAS), two);
    let swing = fixed::mul(Fixed { enc: BIAS + half.into() }, bam::finesine(idx));

    let (viewheight, deltaviewheight) = if cur.playerstate == PST_LIVE {
        spring(cur.viewheight, cur.deltaviewheight)
    } else {
        (cur.viewheight, cur.deltaviewheight)
    };

    let raised = fixed::add(fixed::add(mo.z, viewheight), swing);
    let head = Fixed { enc: mo.ceilingz.enc - 4 * 65536 };
    let viewz = if fixed::gt(raised, head) {
        head
    } else {
        raised
    };
    p = BoxTrait::new(Player { bob, viewz, viewheight, deltaviewheight, ..cur });
}

/// `P_CalcHeight`'s view-height spring: it climbs back to `VIEWHEIGHT` after
/// a hard landing, never falls below half of it, and accelerates by
/// `FRACUNIT/4` a tic while it is moving.
fn spring(viewheight: Fixed, deltaviewheight: Fixed) -> (Fixed, Fixed) {
    let mut vh = fixed::add(viewheight, deltaviewheight);
    let mut dv = deltaviewheight;
    let top = Fixed { enc: BIAS + VIEWHEIGHT };
    if fixed::gt(vh, top) {
        vh = top;
        dv = fixed::ZERO;
    }
    let floor = Fixed { enc: BIAS + HALF_VIEWHEIGHT };
    if fixed::lt(vh, floor) {
        vh = floor;
        if fixed::le(dv, fixed::ZERO) {
            dv = Fixed { enc: BIAS + 1 };
        }
    }
    if dv != fixed::ZERO {
        dv = Fixed { enc: dv.enc + 16384 };
        if dv == fixed::ZERO {
            dv = Fixed { enc: BIAS + 1 };
        }
    }
    (vh, dv)
}

// ---------------------------------------------------------------------------
// P_DeathThink
// ---------------------------------------------------------------------------

/// `P_DeathThink`: the camera sinks to six units and turns toward the killer.
///
/// `BT_USE` starts `PST_REBORN` in vanilla; a proven single-player run has no
/// respawn — the segment ends with D14's `status = 1 (DEAD)` — so the press
/// is ignored here and `doom_game` reads [`Player::playerstate`].
#[inline(always)]
pub fn death_think(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    death_think_in(cx, ref g, ref rng, ref bp, ref bm, ref events);
    leave(bp, bm, ref p, ref mo);
}

fn death_think_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
) {
    move_psprites_in(env, ref g, ref rng, ref p, ref mo, ref events);
    let six = Fixed { enc: BIAS + SIX_UNITS };
    let cur = p.unbox();
    let mut vh = cur.viewheight;
    if fixed::gt(vh, six) {
        vh = Fixed { enc: vh.enc - 65536 };
    }
    if fixed::lt(vh, six) {
        vh = six;
    }
    p = BoxTrait::new(Player { viewheight: vh, deltaviewheight: fixed::ZERO, ..cur });
    calc_height_in(ref p, height_of(@mo.unbox()), env.tic);
    death_turn(env, ref p, ref mo);
}

/// The "turn toward the killer" half of `P_DeathThink`, out of line so the
/// three arms of the turn do not each copy the whole tic's live set.
fn death_turn(env: Box<Env>, ref p: Box<Player>, ref mo: Box<Mobj>) {
    let cur = p.unbox();
    let target = if cur.attacker != NO_MOBJ && cur.attacker != cur.mo {
        env.mobjs.get(cur.attacker)
    } else {
        Option::None
    };
    let t = match target {
        Option::Some(b) => b.unbox(),
        Option::None => {
            if cur.damagecount != 0 {
                p = BoxTrait::new(Player { damagecount: dec(cur.damagecount), ..cur });
            }
            return;
        },
    };
    let mut angle = mo.angle;
    let facing = point_to_angle2(mo.x, mo.y, *t.x, *t.y);
    let delta = bam::sub(facing, angle);
    if delta < ANG5 || delta > NEG_ANG5 {
        angle = facing;
        if cur.damagecount != 0 {
            p = BoxTrait::new(Player { damagecount: dec(cur.damagecount), ..cur });
        }
    } else if delta < 0x80000000 {
        angle = bam::add(angle, ANG5);
    } else {
        angle = bam::sub(angle, ANG5);
    }
    mo = BoxTrait::new(Mobj { angle, ..mo.unbox() });
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
    p.pending_weapon = requested_weapon(@p, buttons);
}

/// What `BT_CHANGE` asks for, as the new `pending_weapon` — the current one
/// when the request is refused. Returning the value instead of writing it
/// lets [`buttons`] fold this into its single rebuild of the record.
fn requested_weapon(p: @Player, buttons: u32) -> u32 {
    let requested = div32(buttons & BT_WEAPONMASK, BT_WEAPONSHIFT_NZ);
    let mut new = rd32(WEAPON_OF_BUTTON.span(), requested);
    if new == WP_FIST
        && owns(p, WP_CHAINSAW)
        && !(*p.ready_weapon == WP_CHAINSAW && *p.strength != 0) {
        new = WP_CHAINSAW;
    }
    if new != WP_NOCHANGE && owns(p, new) && new != *p.ready_weapon {
        new
    } else {
        *p.pending_weapon
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
#[inline(always)]
pub fn use_lines(env: Env, ref g: ThingGrid, mo: @Mobj, ref events: Array<PlayerEvent>) {
    use_lines_in(BoxTrait::new(env), ref g, BoxTrait::new(*mo), ref events);
}

fn use_lines_in(env: Box<Env>, ref g: ThingGrid, mo: Box<Mobj>, ref events: Array<PlayerEvent>) {
    let w = env.world.unbox();
    let p1 = Point { x: mo.x, y: mo.y };
    let (s, c) = sin_cos(mo.angle);
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
fn used_line(w: World, mut hits: Span<Intercept>, p1: Point) -> Option<(u32, u8)> {
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
