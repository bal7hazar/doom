// SPDX-License-Identifier: GPL-2.0-only
//! One tic — `P_Ticker`, in the order the four rule crates agreed on:
//!
//! ```text
//!  0. reject an invalid word or a finished game            -> ABORT
//!  1. P_ThingHeightClip on the player if its sector's plane moved last tic
//!  2. doom_specials::player_in_special_sector   (the sector the tic began in)
//!  3. doom_player::player_think                 (momentum, weapon, USE trace)
//!  4. the player's events: Use -> use_line, Shot -> damage_mobj (+ P_NoiseAlert)
//!  5. the player mobj's own P_MobjThinker: xy_movement (Stopped ->
//!     player_stopped, Touch -> touch_special, CrossSpecial -> cross_line),
//!     z_movement (hard landing -> deltaviewheight), fsm::advance
//!  6. one rebuild of the list: the player at its index, the tic's patches
//!     (shot monsters, picked-up items), P_ThingHeightClip in moving sectors
//!  7. doom_monsters::monsters_ticker  (every monster and missile, D3)
//!  8. its events: EV_CROSS -> cross_line, EV_USE -> use_line, EV_KILLED ->
//!     kills, EV_DROP -> a dropped item; synchronize the player's defense
//!  9. doom_specials::specials_ticker  (planes and lights), heights refreshed
//! 10. leveltime += 1; status = EXIT | DEAD | RUNNING
//! ```
//!
//! Two representation decisions shape the code. **The list is rebuilt at
//! most twice a tic**: once here (step 6, skipped on a tic where nothing
//! changed but the monsters) and once inside `monsters_ticker`; every other
//! write is a patch applied in one of those passes or an `append`. And
//! **cross-mobj effects are patches** (the `doom_physics` rule): a shot
//! monster is damaged on a copy and written back in step 6, so two pellets
//! on the same monster compose through `read_mobj`.

use core::num::traits::WrappingAdd;
use doom_monsters::actions::passive;
use doom_monsters::actors::{Actors, none as no_actors, patches_keep_classes, same_class, scan};
use doom_monsters::{
    Ctx as MonsterCtx, EV_CROSS, EV_DROP, EV_KILLED, EV_USE, MonsterEvent, Noise, Patch,
    monsters_ticker_indexed, read_mobj,
};
use doom_physics::{
    Hit, MAX_MOBJS, MF_DROPPED, Mobj, MoveEvent, NO_MOBJ, PlayerDefense, SpawnZ, ThingGrid, World,
    XyOutcome, check_position, damage_mobj, first_free, is_removed, removed_mobj, replace,
    set_thing_position, spawn_mobj, unset_thing_position, xy_movement, z_movement,
};
use doom_player::{
    Env, PST_DEAD, Player, PlayerEvent, WP_CHAINSAW, count_kill, drop_weapon, env_of, has_blue_key,
    player_stopped, player_think, touch_special,
};
use doom_specials::{
    PlayerSector, SpecialsState, cross_line, monster, player, player_in_special_sector,
    specials_ticker, use_line,
};
use fixed::{BIAS, Fixed};
use prng::Prng;
use segment::Status;
use super::level::{
    Ctx, SectorIndex, contains, ctx_of, moving_sectors, occupancy_scan, refresh_heights,
    things_of_sector,
};
use super::setup::status_from;
use super::state::GameState;

/// `1/8` as a `Fixed`: `FixedMul(momz, 1/8)` is `momz >> 3`, floor included.
const EIGHTH: Fixed = Fixed { enc: BIAS + 8192 };

/// One tic of the whole game. Returns the next state and the status D14
/// reports for it; on an invalid input the state comes back untouched with
/// `Abort` (R4-A2: never a panic).
pub fn step_tic(state: GameState, word: felt252) -> (GameState, Status) {
    if state.status != Status::Running || state.leveltime >= segment::MAX_TIC {
        return (state, Status::Abort);
    }
    let cmd = match ticcmd::try_decode(word) {
        Option::Some(c) => c,
        Option::None => { return (state, Status::Abort); },
    };
    let GameState {
        level,
        leveltime,
        status: _,
        noise,
        prng,
        mrng,
        player,
        mobjs,
        specials,
        floor,
        ceil,
        grid,
        actors,
    } = state;
    let me = player.mo;
    let entered = match mobjs.get(me) {
        Option::Some(b) => Option::Some(b.unbox().unbox()),
        Option::None => Option::None,
    };
    let mut mo = match entered {
        Option::Some(m) => m,
        Option::None => {
            let back = GameState {
                level,
                leveltime,
                status: Status::Running,
                noise,
                prng,
                mrng,
                player,
                mobjs,
                specials,
                floor,
                ceil,
                grid,
                actors,
            };
            return (back, Status::Abort);
        },
    };
    let mo0 = mo;
    let ctx = BoxTrait::new(ctx_of(level, floor, ceil));
    let w = ctx.unbox().w;
    let tic = leveltime;
    let mut g = grid;
    let mut rng = prng;
    let mut p = player;
    let mut s = specials;
    let mut noise_now = noise;
    let players = array![me].span();
    let mctx = BoxTrait::new(MonsterCtx { w, players, noise, tic });
    let mut cues: Array<MonsterEvent> = array![];

    // 1. The player rides a lift / ducks a door that moved last tic.
    let clip = moving_sectors(@specials);
    if contains(clip, mo.sector) {
        height_clip(w, mobjs, ref g, ref mo, me);
    }

    // 2. P_PlayerInSpecialSector, for the sector the tic began in.
    let mut damage: u32 = 0;
    let mut secret = false;
    if p.playerstate != PST_DEAD {
        let sector_floor = match floor.get(mo.sector) {
            Option::Some(b) => *b.unbox(),
            Option::None => mo.floorz.enc,
        };
        let ps = PlayerSector {
            sector: mo.sector, on_floor: mo.z.enc == sector_floor, radiation_suit: false,
        };
        let (next, effect, _) = player_in_special_sector(
            s, @ctx.unbox().m, @ctx.unbox().lm, ps, tic,
        );
        s = next;
        damage = effect.damage;
        secret = effect.secret;
    }

    // 3. P_PlayerThink.
    let buttons: u32 = cmd.buttons.into();
    let env = env_of(w, mobjs, me, tic, buttons);
    let mut events: Array<PlayerEvent> = array![];
    player_think(env, ref g, ref rng, ref p, ref mo, word, damage, secret, ref events);

    // 4. What the think did to the rest of the world.
    let mut patches: Array<Patch> = array![];
    let mut drops: Array<Box<Mobj>> = array![];
    let fired = apply_player_events_boxed(
        ctx, mctx, mobjs, ref rng, ref p, ref s, events.span(), ref patches, ref drops, ref cues,
    );
    if fired {
        // P_NoiseAlert(player->mo, player->mo) in P_FireWeapon.
        noise_now = Noise { source: me, sector: mo.sector };
    }

    // 5. The player mobj's P_MobjThinker.
    let input = cmd.forward != 0 || cmd.side != 0;
    player_mobj_thinker_boxed(
        ctx, env, mctx, mobjs, ref g, ref rng, ref p, ref mo, ref s, input, ref patches, ref cues,
    );

    // 6. One rebuild, if anything changed on our side. The derived actor
    // index follows the list (O1): kept when no patch changed a slot's
    // class, rescanned otherwise.
    let (list_in, actors_in) = if mo != mo0 || patches.len() != 0 || clip.len() != 0 {
        rebuild_list_in(w, mobjs, ref g, mo, me, patches.span(), clip, actors)
    } else {
        (mobjs, actors)
    };

    // 7. The monsters and the missiles.
    let mut defense = PlayerDefense {
        mo: me,
        armor_points: p.armor_points,
        armor_type: p.armor_type,
        damagecount: p.damagecount,
        attacker: p.attacker,
    };
    let (list_out, r2, mev, actors_out) = monsters_ticker_indexed(
        w, list_in, actors_in, ref g, players, noise_now, tic, rng, ref defense,
    );
    rng = r2;
    let mut out = list_out;
    let mut actors_now = actors_out;
    // Set when a write below may change a slot's class: the index is
    // rescanned from the final list.
    let mut rescan = drops.len() != 0;

    // 8. Their events, then synchronize the player after per-impact damage.
    apply_monster_events_boxed(
        ctx, BoxTrait::new(w), me, ref p, ref s, out.span(), mev.span(), ref drops, ref cues,
    );
    let after = *out.span().at(me);
    if after.health < mo.health && p.playerstate != PST_DEAD {
        let fixed_mo = reconcile_player(env, ref g, ref rng, ref p, after.unbox(), defense);
        if !same_class(
            after.kind, after.flags, after.cell, fixed_mo.kind, fixed_mo.flags, fixed_mo.cell,
        ) {
            rescan = true;
        }
        replace(ref out, me, BoxTrait::new(fixed_mo));
    }
    place_drops(w, ref g, ref out, drops.span());
    if rescan {
        actors_now = scan(out.span());
    }

    // 9. Doors, lifts, floors, lights.
    let movers_before = s.movers.len();
    let occupancy = occupancy_scan(out.span());
    let (s2, r3, _) = specials_ticker(@occupancy, s, ctx.unbox().tables, tic, rng, w.rndtable);
    s = s2;
    rng = r3;
    let (floor2, ceil2) = refresh_heights(ctx.unbox(), floor, ceil, movers_before, @s);

    // 10. The clock and the verdict.
    let status = status_from(s.exit, p.playerstate);
    let next = GameState {
        level,
        leveltime: leveltime.wrapping_add(1),
        status,
        noise: noise_now,
        prng: rng,
        mrng,
        player: p,
        mobjs: out.span(),
        specials: s,
        floor: floor2,
        ceil: ceil2,
        grid: g,
        actors: actors_now,
    };
    (next, status)
}

// ---------------------------------------------------------------------------
// The pieces
// ---------------------------------------------------------------------------

/// `P_ThingHeightClip`: after a plane moved under or over a thing, recompute
/// its floor and ceiling and keep it on the floor it stood on (or under the
/// ceiling it hit). `check_position` is `P_CheckPosition` at the thing's own
/// coordinates; the touch events it may report are not ours to apply here.
pub fn height_clip(w: World, mobjs: Span<Box<Mobj>>, ref g: ThingGrid, ref m: Mobj, me: u32) {
    let onfloor = m.z == m.floorz;
    let mut ignored: Array<MoveEvent> = array![];
    let c = check_position(w, mobjs, ref g, @m, me, m.x, m.y, ref ignored);
    m.floorz = c.floorz;
    m.ceilingz = c.ceilingz;
    if onfloor {
        m.z = m.floorz;
    } else if fixed::gt(fixed::add(m.z, m.height), m.ceilingz) {
        m.z = fixed::sub(m.ceilingz, m.height);
    }
}

/// Apply what `player_think` reported. Returns `true` if a weapon fired
/// (`P_NoiseAlert`).
fn apply_player_events_boxed(
    ctx: Box<Ctx>,
    mctx: Box<MonsterCtx>,
    mobjs: Span<Box<Mobj>>,
    ref rng: Prng,
    ref p: Player,
    ref s: SpecialsState,
    mut events: Span<PlayerEvent>,
    ref patches: Array<Patch>,
    ref drops: Array<Box<Mobj>>,
    ref cues: Array<MonsterEvent>,
) -> bool {
    let mut fired = false;
    while let Option::Some(e) = events.pop_front() {
        match *e {
            PlayerEvent::Shot((
                hit, damage,
            )) => {
                fired = true;
                match hit {
                    Hit::Thing((
                        idx, _, _,
                    )) => {
                        shoot_thing(
                            ctx,
                            mctx,
                            mobjs,
                            ref rng,
                            ref p,
                            idx,
                            damage,
                            ref patches,
                            ref drops,
                            ref cues,
                        );
                    },
                    _ => {},
                }
            },
            PlayerEvent::Picked(_) => {},
            PlayerEvent::Use((
                line, side,
            )) => {
                let (next, _, _) = use_line(
                    s, @ctx.unbox().m, @ctx.unbox().lm, line, side, player(has_blue_key(@p)),
                );
                s = next;
            },
        }
    }
    fired
}

/// One bullet (or punch) of the player landing on mobj `idx`: `P_DamageMobj`
/// with the chainsaw's no-thrust rule, the reaction action (pain, scream,
/// fall), the kill tally and the dropped item.
fn shoot_thing(
    ctx: Box<Ctx>,
    mctx: Box<MonsterCtx>,
    mobjs: Span<Box<Mobj>>,
    ref rng: Prng,
    ref p: Player,
    idx: u32,
    damage: u32,
    ref patches: Array<Patch>,
    ref drops: Array<Box<Mobj>>,
    ref cues: Array<MonsterEvent>,
) {
    let me = p.mo;
    let mut t = read_mobj(mobjs, patches.span(), idx).unbox();
    let thrust = p.ready_weapon != WP_CHAINSAW;
    let out = damage_mobj(ctx.unbox().w, mobjs, ref rng, ref t, idx, me, me, damage, thrust);
    passive(mctx.unbox(), ref rng, ref t, idx, out.action, ref cues);
    if out.counts_kill {
        count_kill(ref p);
    }
    patches.append(Patch { idx, mo: BoxTrait::new(t) });
    match out.drop {
        Option::Some(item) => { drops.append(BoxTrait::new(item)); },
        Option::None => {},
    }
}

/// `P_MobjThinker` on the player's own mobj: movement under Doom's two
/// guards, then the state machine (`S_PLAY_RUN*`, the death frames).
fn player_mobj_thinker_boxed(
    ctx: Box<Ctx>,
    env: Env,
    mctx: Box<MonsterCtx>,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref s: SpecialsState,
    input: bool,
    ref patches: Array<Patch>,
    ref cues: Array<MonsterEvent>,
) {
    let w = mctx.unbox().w;
    let me = p.mo;
    if mo.momx != fixed::ZERO || mo.momy != fixed::ZERO {
        let mut moves: Array<MoveEvent> = array![];
        let out = xy_movement(w, mobjs, ref g, ref mo, me, input, true, ref moves);
        if out == XyOutcome::Stopped {
            player_stopped(env, ref mo);
        }
        apply_move_events_boxed(ctx, mobjs, ref g, ref p, ref mo, ref s, moves.span(), ref patches);
    }
    if mo.z != mo.floorz || mo.momz != fixed::ZERO {
        let z = z_movement(ref mo, Option::None);
        if z.hard_landing != fixed::ZERO {
            // "Squat down": deltaviewheight = momz >> 3 (and the oof).
            p.deltaviewheight = fixed::mul(z.hard_landing, EIGHTH);
        }
    }
    if mo.tics != fsm::FOREVER {
        let (st, tc, action) = fsm::advance(w.states, mo.state, mo.tics);
        mo.state = st;
        mo.tics = tc;
        if action != fsm::NO_ACTION {
            passive(mctx.unbox(), ref rng, ref mo, me, action, ref cues);
        }
    }
}

/// What the player's move touched: items (`P_TouchSpecialThing`, the item
/// removed on a pickup) and walk-over specials (`P_CrossSpecialLine`).
fn apply_move_events_boxed(
    ctx: Box<Ctx>,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref p: Player,
    ref mo: Mobj,
    ref s: SpecialsState,
    mut moves: Span<MoveEvent>,
    ref patches: Array<Patch>,
) {
    let key = has_blue_key(@p);
    while let Option::Some(e) = moves.pop_front() {
        match *e {
            MoveEvent::CrossSpecial((
                line, side,
            )) => {
                let (next, _) = cross_line(
                    s, @ctx.unbox().m, @ctx.unbox().lm, line, side, player(key),
                );
                s = next;
            },
            MoveEvent::Touch(idx) => {
                let item = read_mobj(mobjs, patches.span(), idx);
                if !is_removed(@item.unbox()) {
                    if touch_special(ref p, ref mo, @item.unbox()) {
                        unset_thing_position(ref g, @item.unbox(), idx);
                        patches.append(Patch { idx, mo: BoxTrait::new(removed_mobj()) });
                    }
                }
            },
            MoveEvent::MissileHit(_) => {},
        }
    }
}

/// Step 6: the one list pass of this crate. Writes the player's mobj at
/// `me`, every patch at its index, and height-clips the things standing in
/// a sector whose plane moved last tic.
///
/// S7 §8 in practice: a Cairo loop carries its whole live set through
/// every iteration, so a per-mobj loop holding the 67-felt `World` cost
/// 450 steps a slot (94 000 a tic). The patches are sorted (they are a
/// handful) and the unpatched runs between them are copied with
/// `append_span`, whose loop carries two spans; the clip case first finds
/// the things to clip by reading one felt per slot, then joins the patch
/// list.
pub fn rebuild_list(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    mo: Mobj,
    me: u32,
    patches: Span<Patch>,
    clip: Span<u32>,
) -> Span<Box<Mobj>> {
    let (list, _) = rebuild_list_in(w, mobjs, ref g, mo, me, patches, clip, no_actors());
    list
}

/// [`rebuild_list`] carrying the derived actor index (O1): `actors` is the
/// index of `mobjs`; the result's index is the same one when every written
/// slot (the player, the patches, the clipped things) kept its class, a
/// fresh `scan` of the new list otherwise.
fn rebuild_list_in(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    mo: Mobj,
    me: u32,
    patches: Span<Patch>,
    clip: Span<u32>,
    actors: Actors,
) -> (Span<Box<Mobj>>, Actors) {
    let mut sorted = insert_patch(
        array![], BoxTrait::new(Patch { idx: me, mo: BoxTrait::new(mo) }),
    );
    let mut ps = patches;
    while let Option::Some(pt) = ps.pop_front() {
        sorted = insert_patch(sorted, BoxTrait::new(*pt));
    }
    if clip.len() != 0 {
        sorted = clip_patches_scan(BoxTrait::new(w), mobjs, ref g, sorted, clip, me);
    }
    let list = copy_patched(mobjs, sorted.span());
    let index = if patches_keep_classes(mobjs, sorted.span()) {
        actors
    } else {
        scan(list)
    };
    (list, index)
}

/// `sorted` with `pt` inserted at its index (replacing an entry with the
/// same index: the later patch of a tic composes the earlier one).
fn insert_patch(sorted: Array<Patch>, pt: Box<Patch>) -> Array<Patch> {
    let mut out: Array<Patch> = array![];
    let mut placed = false;
    let mut src = sorted.span();
    while let Option::Some(cur) = src.pop_front() {
        if !placed && pt.unbox().idx <= *cur.idx {
            out.append(pt.unbox());
            placed = true;
            if pt.unbox().idx == *cur.idx {
                continue;
            }
        }
        out.append(*cur);
    }
    if !placed {
        out.append(pt.unbox());
    }
    out
}

/// The list with the sorted `patches` written in: the unpatched runs are
/// `append_span`ed, the patched slots appended one by one.
fn copy_patched(mobjs: Span<Box<Mobj>>, mut patches: Span<Patch>) -> Span<Box<Mobj>> {
    let n = mobjs.len();
    let mut out: Array<Box<Mobj>> = array![];
    let mut from: u32 = 0;
    while let Option::Some(pt) = patches.pop_front() {
        let idx = *pt.idx;
        if idx < n && idx >= from {
            out.append_span(mobjs.slice(from, idx - from));
            out.append(*pt.mo);
            from = idx + 1;
        }
    }
    if from < n {
        out.append_span(mobjs.slice(from, n - from));
    }
    out.span()
}

/// `P_ThingHeightClip` on every thing (other than the player, already
/// done) whose centre is in a `clip` sector, as patches merged into
/// `sorted` — the same patches as [`clip_patches_scan`], the scan the
/// ticker runs, found through the blockmap (O3, not yet wired into the
/// tic): the slots linked in the cells of each clipping sector,
/// then the slots off the grid, each clipped when its record's sector is
/// one of `clip`. The order of the visits does not show in the result: a
/// clip reads the original list and grid and writes its own slot's patch,
/// `insert_patch` keeps the patches in slot order, and clipping a slot
/// twice (two movers on one sector) rewrites the same record — the clip
/// of a clipped record is itself, `check_position` not reading `z`.
pub(crate) fn clip_patches(
    w: Box<World>,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    sorted: Array<Patch>,
    clip: Span<u32>,
    me: u32,
    index: SectorIndex,
) -> Array<Patch> {
    let grid = w.unbox().map.grid;
    let mut out = sorted;
    let mut sectors = clip;
    while let Option::Some(s) = sectors.pop_front() {
        let things = things_of_sector(ref g, index.cells, grid, *s);
        out = clip_slots(w, mobjs, ref g, out, clip, me, things);
    }
    clip_slots(w, mobjs, ref g, out, clip, me, index.off_grid)
}

/// The clip of every slot of `slots` whose record's sector is one of
/// `clip`, the player excepted: the body of the scan, on the candidates.
fn clip_slots(
    w: Box<World>,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    sorted: Array<Patch>,
    clip: Span<u32>,
    me: u32,
    mut slots: Span<u32>,
) -> Array<Patch> {
    let mut out = sorted;
    while let Option::Some(bi) = slots.pop_front() {
        let i = *bi;
        let record = match mobjs.get(i) {
            Option::Some(b) => *b.unbox(),
            Option::None => { continue; },
        };
        if i != me && contains(clip, record.sector) {
            let mut cur = match patch_at(out.span(), i) {
                Option::Some(p) => p.unbox(),
                Option::None => record.unbox(),
            };
            if !is_removed(@cur) {
                height_clip(w.unbox(), mobjs, ref g, ref cur, i);
                out = insert_patch(out, BoxTrait::new(Patch { idx: i, mo: BoxTrait::new(cur) }));
            }
        }
    }
    out
}

/// The clip of the ticker: every slot of the list read for its sector,
/// and the oracle [`clip_patches`] is compared with (same patches, same
/// order).
pub(crate) fn clip_patches_scan(
    w: Box<World>,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    sorted: Array<Patch>,
    clip: Span<u32>,
    me: u32,
) -> Array<Patch> {
    let mut out = sorted;
    let n = mobjs.len();
    let mut i: u32 = doom_physics::maputl::opaque_zero(n);
    while i != n {
        let sector = mobjs.at(i).sector;
        if i != me && contains(clip, sector) {
            let mut cur = match patch_at(out.span(), i) {
                Option::Some(p) => p.unbox(),
                Option::None => mobjs.at(i).unbox(),
            };
            if !is_removed(@cur) {
                height_clip(w.unbox(), mobjs, ref g, ref cur, i);
                out = insert_patch(out, BoxTrait::new(Patch { idx: i, mo: BoxTrait::new(cur) }));
            }
        }
        i = i.wrapping_add(1);
    }
    out
}

/// The patch for slot `i`, if any.
fn patch_at(mut patches: Span<Patch>, i: u32) -> Option<Box<Mobj>> {
    let mut found: Option<Box<Mobj>> = Option::None;
    while let Option::Some(pt) = patches.pop_front() {
        if *pt.idx == i {
            found = Option::Some(*pt.mo);
        }
    }
    found
}

/// Step 8: what the monsters did to the world outside their own list.
fn apply_monster_events_boxed(
    ctx: Box<Ctx>,
    w: Box<World>,
    me: u32,
    ref p: Player,
    ref s: SpecialsState,
    out: Span<Box<Mobj>>,
    mut events: Span<MonsterEvent>,
    ref drops: Array<Box<Mobj>>,
    ref cues: Array<MonsterEvent>,
) {
    while let Option::Some(e) = events.pop_front() {
        let ev = *e;
        if ev.kind == EV_CROSS {
            let side: u8 = match ev.b.try_into() {
                Option::Some(v) => v,
                Option::None => 0,
            };
            let (next, _) = cross_line(s, @ctx.unbox().m, @ctx.unbox().lm, ev.a, side, monster());
            s = next;
        } else if ev.kind == EV_USE {
            let (next, _, _) = use_line(s, @ctx.unbox().m, @ctx.unbox().lm, ev.a, 0, monster());
            s = next;
        } else if ev.kind == EV_KILLED {
            if ev.a == me {
                count_kill(ref p);
            }
        } else if ev.kind == EV_DROP {
            // `P_KillMobj`: the item at the corpse, ONFLOORZ, MF_DROPPED.
            match out.get(ev.who) {
                Option::Some(b) => {
                    let corpse = b.unbox().as_snapshot().unbox();
                    let mut item = spawn_mobj(
                        w.unbox(), ev.a, *corpse.x, *corpse.y, SpawnZ::OnFloor,
                    );
                    item.flags = item.flags | MF_DROPPED;
                    drops.append(BoxTrait::new(item));
                },
                Option::None => {},
            }
        } else {
            cues.append(ev);
        }
    }
}

/// Synchronize the Player record from the already-resolved impacts. Armor,
/// pain and death were decided in order by physics; no mobj is resurrected.
/// The weapon is dropped only on the first live -> dead transition.
pub fn reconcile_player(
    env: Env, ref g: ThingGrid, ref rng: Prng, ref p: Player, after: Mobj, defense: PlayerDefense,
) -> Mobj {
    p.armor_points = defense.armor_points;
    p.armor_type = defense.armor_type;
    p.damagecount = defense.damagecount;
    p.attacker = defense.attacker;
    p.health = match after.health.try_into() {
        Option::Some(v) => v,
        Option::None => 0,
    };
    let mut mo = after;
    if p.health == 0 && p.playerstate != PST_DEAD {
        p.playerstate = PST_DEAD;
        let mut ignored: Array<PlayerEvent> = array![];
        drop_weapon(env, ref g, ref rng, ref p, ref mo, ref ignored);
    }
    mo
}

/// Give every dropped item a slot: appended while the list has room,
/// otherwise a freed slot, otherwise lost (D3's fixed maximum; documented).
pub fn place_drops(
    w: World, ref g: ThingGrid, ref out: Array<Box<Mobj>>, mut drops: Span<Box<Mobj>>,
) {
    while let Option::Some(d) = drops.pop_front() {
        let mut item = d.unbox();
        if out.len() < MAX_MOBJS {
            let idx = out.len();
            set_thing_position(@w.map, ref g, ref item, idx);
            out.append(BoxTrait::new(item));
        } else {
            let idx = first_free(out.span());
            if idx != NO_MOBJ {
                set_thing_position(@w.map, ref g, ref item, idx);
                replace(ref out, idx, BoxTrait::new(item));
            }
        }
    }
}

// Public adapters preserve the value API; tic-internal calls share boxed contexts.
pub fn apply_player_events(
    ctx: Ctx,
    mctx: MonsterCtx,
    mobjs: Span<Box<Mobj>>,
    ref rng: Prng,
    ref p: Player,
    ref s: SpecialsState,
    mut events: Span<PlayerEvent>,
    ref patches: Array<Patch>,
    ref drops: Array<Box<Mobj>>,
    ref cues: Array<MonsterEvent>,
) -> bool {
    apply_player_events_boxed(
        BoxTrait::new(ctx),
        BoxTrait::new(mctx),
        mobjs,
        ref rng,
        ref p,
        ref s,
        events,
        ref patches,
        ref drops,
        ref cues,
    )
}

pub fn player_mobj_thinker(
    ctx: Ctx,
    env: Env,
    mctx: MonsterCtx,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref s: SpecialsState,
    input: bool,
    ref patches: Array<Patch>,
    ref cues: Array<MonsterEvent>,
) {
    player_mobj_thinker_boxed(
        BoxTrait::new(ctx),
        env,
        BoxTrait::new(mctx),
        mobjs,
        ref g,
        ref rng,
        ref p,
        ref mo,
        ref s,
        input,
        ref patches,
        ref cues,
    )
}

pub fn apply_move_events(
    ctx: Ctx,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref p: Player,
    ref mo: Mobj,
    ref s: SpecialsState,
    mut moves: Span<MoveEvent>,
    ref patches: Array<Patch>,
) {
    apply_move_events_boxed(
        BoxTrait::new(ctx), mobjs, ref g, ref p, ref mo, ref s, moves, ref patches,
    )
}

pub fn apply_monster_events(
    ctx: Ctx,
    w: World,
    me: u32,
    ref p: Player,
    ref s: SpecialsState,
    out: Span<Box<Mobj>>,
    mut events: Span<MonsterEvent>,
    ref drops: Array<Box<Mobj>>,
    ref cues: Array<MonsterEvent>,
) {
    apply_monster_events_boxed(
        BoxTrait::new(ctx), BoxTrait::new(w), me, ref p, ref s, out, events, ref drops, ref cues,
    )
}
