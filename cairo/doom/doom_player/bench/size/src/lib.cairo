// SPDX-License-Identifier: GPL-2.0-only
//! The "with the player" side of `doom_player`'s bytecode measurement: every
//! facade entry point called once, on the real level. `../baseline` loads the same data, links the
//! same crates, calls every function of them that `doom_player` reaches, and
//! calls nothing of `doom_player`.
//!
//! Facade calls are statements tagged `// SIZE:<module>`, so that
//! `../size_split.py` can rebuild this file with one module's calls at a
//! time and attribute the words.

use doom_map::{LevelId, genesis, load};
use doom_physics::{
    MF_SPECIAL, Mobj, NO_MOBJ, ThingGrid, World, new_grid, removed_mobj, set_thing_position,
    world_of,
};
use doom_player::{
    PlayerEvent, absorb, bring_up_weapon, bullet_slope, calc_height, chain, change_weapon,
    check_ammo, count_kill, damage_player, death_think, drop_weapon, env_of, give_ammo, give_armor,
    give_body, give_card, give_strength, give_weapon, move_player, move_psprites, onground,
    player_stopped, player_think, player_tic, push_felts, set_psprite, spawn, thrust, touch_special,
    use_lines,
};
use doom_things::tables::KIND_MISC2; // SIZE:inter
use prng::from_index;
use ticcmd::TicCmd;

#[executable]
fn main(op: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1); // SIZE:tic
    let g0 = genesis(LevelId::E1M1);
    let w: World = world_of(@m);
    let mut acc: felt252 = op.into();
    let zero = op - op;
    let (mut p, mut mo) = spawn(w, zero, g0.start, g0.angle);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut rng = from_index(1); // SIZE:inter
    let mut events: Array<PlayerEvent> = array![];
    let word = tic_word(zero); // SIZE:think
    // `op`-derived arguments, never literals: a literal specialises the
    // callee and this program then measures a folded copy (S7 §8 rule 7).
    let e = env_of(w, array![BoxTrait::new(mo)].span(), zero, op, zero + 3); // SIZE:inter
    let mut felts: Array<felt252> = array![];
    let mut thing: Mobj = removed_mobj(); // SIZE:inter
    // `op - op` is a zero the compiler cannot see: a literal `kind` here
    // specialised `touch_special` and `take_health` on it and put a second,
    // folded copy of the pickup dispatch in this program (S7 §8 rule 7).
    thing.kind = KIND_MISC2 + (op - op); // SIZE:inter
    thing.flags = MF_SPECIAL; // SIZE:inter
    thing.z = mo.z; // SIZE:inter
    thing.height = fixed::from_units(16); // SIZE:inter

    push_felts(ref felts, @p); // SIZE:state
    acc += felts.len().into(); // SIZE:state

    acc += bool_felt(give_ammo(ref p, zero, zero + 1)); // SIZE:inter
    acc += bool_felt(give_weapon(ref p, zero + 2, zero == 0)); // SIZE:inter
    acc += bool_felt(give_body(ref p, ref mo, zero + 10)); // SIZE:inter
    acc += bool_felt(give_armor(ref p, zero + 1)); // SIZE:inter
    give_card(ref p, zero + 1); // SIZE:inter
    acc += bool_felt(give_strength(ref p, ref mo)); // SIZE:inter
    acc += bool_felt(touch_special(ref p, ref mo, @thing)); // SIZE:inter
    count_kill(ref p); // SIZE:inter
    acc += absorb(ref p, zero + 9).into(); // SIZE:inter
    acc += hurt_words(e, ref g, ref rng, ref p, ref mo, ref events); // SIZE:inter

    move_psprites(e, ref g, ref rng, ref p, ref mo, ref events); // SIZE:weapon
    set_psprite(
        e, ref g, ref rng, ref p, ref mo, ref events, zero, chain(zero + 1).attack, zero,
    ); // SIZE:weapon
    bring_up_weapon(e, ref g, ref rng, ref p, ref mo, ref events, zero); // SIZE:weapon
    drop_weapon(e, ref g, ref rng, ref p, ref mo, ref events); // SIZE:weapon
    acc += bool_felt(check_ammo(e, ref g, ref rng, ref p, ref mo, ref events, zero)); // SIZE:weapon
    acc += bullet_slope(w, array![BoxTrait::new(mo)].span(), ref g, @mo, zero).enc; // SIZE:weapon

    player_think(
        e, ref g, ref rng, ref p, ref mo, word, zero + 5, zero == 0, ref events,
    ); // SIZE:think
    move_player(
        e, ref p, ref mo, move_arg(zero, 25), move_arg(zero, 3), move_arg(zero, 256),
    ); // SIZE:think
    thrust(ref mo, mo.angle, move_arg(zero, 25)); // SIZE:think
    calc_height(ref p, @mo, op); // SIZE:think
    death_think(e, ref g, ref rng, ref p, ref mo, ref events); // SIZE:think
    change_weapon(ref p, zero + 4 + 8); // SIZE:think
    use_lines(e, ref g, @mo, ref events); // SIZE:think
    player_stopped(e, ref mo); // SIZE:think
    acc += bool_felt(onground(@mo)); // SIZE:think

    acc += tic_words(e, @m, @lm, ref g, ref rng, ref p, ref mo, word, ref events); // SIZE:tic

    acc + events.len().into() + p.health.into() + mo.z.enc
}

/// Build an opaque ticcmd for the facade-size harness.
fn tic_word(zero: u32) -> felt252 {
    ticcmd::encode(
        TicCmd {
            forward: move_arg(zero, 25),
            side: move_arg(zero, 3),
            angle_turn: move_arg(zero, 256),
            buttons: (zero + 3).try_into().unwrap(),
        },
    )
}

fn move_arg(zero: u32, amount: u32) -> i64 {
    (zero + amount).into()
}

fn bool_felt(b: bool) -> felt252 {
    if b {
        1
    } else {
        0
    }
}

/// Return the damage verdict as a felt for this harness.
fn hurt_words(
    e: doom_player::Env,
    ref g: ThingGrid,
    ref rng: prng::Prng,
    ref p: doom_player::Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) -> felt252 {
    let zero = e.tic - e.tic;
    bool_felt(
        damage_player(
            e,
            ref g,
            ref rng,
            ref p,
            ref mo,
            ref events,
            NO_MOBJ - zero,
            NO_MOBJ - zero,
            zero + 7,
            zero != 0,
        )
            .died,
    )
}

fn tic_words(
    e: doom_player::Env,
    m: @doom_map::LevelMap,
    lm: @doom_specials::SpecialsMap,
    ref g: ThingGrid,
    ref rng: prng::Prng,
    ref p: doom_player::Player,
    ref mo: Mobj,
    word: felt252,
    ref events: Array<PlayerEvent>,
) -> felt252 {
    let (specials, spawn_rng) = doom_specials::spawn_specials(
        m, lm, from_index(1), doom_things::rndtable(),
    );
    let _ = spawn_rng;
    let (next, cues) = player_tic(
        e, m, lm, specials, ref g, ref rng, ref p, ref mo, word, ref events,
    );
    cues.len().into() + next.secrets.into()
}
