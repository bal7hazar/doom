//! Game state, P_PlayerThink-lite, and the tic loop.

use core::poseidon::poseidon_hash_span;

use crate::ai::monster_think;
use crate::bam::{angle_add, angle_sub, cosine, sine};
use crate::bsp::point_in_subsector;
use crate::fixed::{Sf, bias_add, fixed_mul, sf_add, sf_zero};
use crate::mapdata::{
    MON_ANGLE, MON_SECTOR, MON_X, MON_Y, PLAYER_ANGLE, PLAYER_SECTOR, PLAYER_X, PLAYER_Y, S_FLOOR,
    SS_SECTOR,
};
use crate::mobj::{Mobj, Opts, PLAYER_RADIUS, ST_SPAWN};
use crate::physics::{path_traverse, try_move};

/// Doom's ORIG_FRICTION, 0xE800 in 16.16.
const FRICTION: felt252 = 59392;
/// Doom's forwardmove[1] * 2048 for a running player.
const MOVE_UNIT: felt252 = 2048;
/// Doom scales `ticcmd.angleturn` by 1 << 16; the script therefore stores the
/// BAM delta directly, because `turn * 65536` overflows u32 for a left turn.
const TURN_LEFT: u32 = 7864320; //  120 << 16
const TURN_RIGHT: u32 = 4285136896; // -150 << 16 mod 2^32

pub const SC_PLAYER: u32 = 0;
pub const SC_DORMANT: u32 = 1;
pub const SC_AWAKE: u32 = 2;
pub const SC_HITSCAN: u32 = 3;

#[derive(Drop)]
pub struct GameState {
    pub player: Mobj,
    pub mobjs: Array<Mobj>,
    pub rng: u32,
    pub tic: u32,
    pub acc: felt252,
    pub kills: u32,
    pub shots: u32,
}

fn mk_player() -> Mobj {
    Mobj {
        x: PLAYER_X,
        y: PLAYER_Y,
        momx: sf_zero(),
        momy: sf_zero(),
        angle: PLAYER_ANGLE,
        sector: PLAYER_SECTOR,
        floorz: *S_FLOOR.span().at(PLAYER_SECTOR),
        health: 100,
        state: ST_SPAWN,
        tics: 0,
        movedir: 0,
        movecount: 0,
        threshold: 0,
        awake: 1,
        sight_ok: 0,
        sight_tic: 0,
        id: 0,
    }
}

pub fn genesis(scenario: u32) -> GameState {
    let mut mobjs: Array<Mobj> = array![];
    if scenario != SC_PLAYER {
        let mx = MON_X.span();
        let my = MON_Y.span();
        let ma = MON_ANGLE.span();
        let ms = MON_SECTOR.span();
        let mut i: u32 = 0;
        while i != 5 {
            let sec = *ms.at(i);
            mobjs
                .append(
                    Mobj {
                        x: *mx.at(i),
                        y: *my.at(i),
                        momx: sf_zero(),
                        momy: sf_zero(),
                        angle: *ma.at(i),
                        sector: sec,
                        floorz: *S_FLOOR.span().at(sec),
                        health: 60,
                        state: ST_SPAWN,
                        tics: 8,
                        movedir: i % 8,
                        movecount: 0,
                        threshold: 0,
                        // SC_AWAKE / SC_HITSCAN start the monsters already chasing
                        awake: if scenario == SC_DORMANT {
                            0
                        } else {
                            1
                        },
                        sight_ok: 0,
                        sight_tic: 0,
                        id: i,
                    },
                );
            i += 1;
        }
    }
    GameState {
        player: mk_player(), mobjs, rng: 0, tic: 0, acc: 1, kills: 0, shots: 0,
    }
}

/// Scripted ticcmd: a repeating walk-and-turn pattern, deterministic.
/// Returns (forwardmove, sidemove, angleturn, fire).
pub fn script_cmd(t: u32) -> (Sf, Sf, u32, bool) {
    let phase = t % 70;
    let fwd = if phase < 50 {
        Sf { m: 25, neg: 0 }
    } else {
        Sf { m: 12, neg: 1 }
    };
    let side = if phase >= 20 && phase < 30 {
        Sf { m: 20, neg: 0 }
    } else if phase >= 55 && phase < 62 {
        Sf { m: 20, neg: 1 }
    } else {
        Sf { m: 0, neg: 0 }
    };
    let turn: u32 = if phase < 10 {
        TURN_LEFT
    } else if phase >= 35 && phase < 45 {
        TURN_RIGHT
    } else {
        0
    };
    (fwd, side, turn, t % 10 == 0)
}

fn thrust(momx: Sf, momy: Sf, angle: u32, move_: Sf) -> (Sf, Sf) {
    let m = Sf { m: move_.m * MOVE_UNIT, neg: move_.neg };
    let cx = fixed_mul(m, cosine(angle));
    let cy = fixed_mul(m, sine(angle));
    (sf_add(momx, cx), sf_add(momy, cy))
}

/// P_PlayerThink + P_XYMovement-lite (no slide: a blocked move stops).
fn player_think(p: Mobj, t: u32, opts: Opts) -> Mobj {
    let (fwd, side, turn, _fire) = script_cmd(t);
    let mut n = p;
    if turn != 0 {
        n.angle = angle_add(n.angle, turn);
    }
    let mut mx = n.momx;
    let mut my = n.momy;
    if fwd.m != 0 {
        let (a, b) = thrust(mx, my, n.angle, fwd);
        mx = a;
        my = b;
    }
    if side.m != 0 {
        let (a, b) = thrust(mx, my, angle_sub(n.angle, 0x40000000_u32), side);
        mx = a;
        my = b;
    }
    // P_XYMovement
    if mx.m != 0 || my.m != 0 {
        let nx = bias_add(n.x, mx);
        let ny = bias_add(n.y, my);
        let r = try_move(nx, ny, PLAYER_RADIUS, opts);
        if r.ok {
            n.x = nx;
            n.y = ny;
            n.sector = r.sector;
            n.floorz = r.floorz;
        } else {
            mx = sf_zero();
            my = sf_zero();
        }
    }
    // friction
    n.momx = Sf { m: fixed_mul(mx, Sf { m: FRICTION, neg: 0 }).m, neg: mx.neg };
    n.momy = Sf { m: fixed_mul(my, Sf { m: FRICTION, neg: 0 }).m, neg: my.neg };
    n
}

pub fn step_tic(st: GameState, scenario: u32, opts: Opts) -> GameState {
    let GameState { player, mobjs, rng, tic, acc, kills, shots } = st;
    let p = player_think(player, tic, opts);

    let mut rng2 = rng;
    let mut kills2 = kills;
    let mut shots2 = shots;
    let mut acc2 = acc;

    // one hitscan every 10 tics
    if scenario == SC_HITSCAN && tic % 10 == 0 {
        let c = cosine(p.angle);
        let s = sine(p.angle);
        let ex = bias_add(p.x, Sf { m: c.m * 2048, neg: c.neg });
        let ey = bias_add(p.y, Sf { m: s.m * 2048, neg: s.neg });
        let hit = path_traverse(p.x, p.y, ex, ey, opts);
        shots2 += 1;
        acc2 = acc2 * 5 + hit.into();
    }

    // monsters
    let mut out: Array<Mobj> = array![];
    let src = mobjs.span();
    let nm = src.len();
    let mut i: u32 = 0;
    while i != nm {
        let m = *src.at(i);
        let (m2, r2, dmg) = monster_think(m, p.x, p.y, p.sector, tic, rng2, opts);
        rng2 = r2;
        if dmg != 0 {
            kills2 += 1;
        }
        acc2 = acc2 * 3 + m2.x + m2.y + m2.angle.into() + dmg;
        out.append(m2);
        i += 1;
    }

    acc2 = acc2 * 7 + p.x + p.y + p.angle.into() + p.sector.into();
    GameState {
        player: p, mobjs: out, rng: rng2, tic: tic + 1, acc: acc2, kills: kills2, shots: shots2,
    }
}

/// Run `n_tics` and return a checksum of the final state, so that nothing in
/// the simulation can be elided by the compiler.
pub fn run(scenario: u32, n_tics: u32, opts: Opts) -> felt252 {
    let mut st = genesis(scenario);
    let mut t: u32 = 0;
    while t != n_tics {
        st = step_tic(st, scenario, opts);
        t += 1;
    }
    checksum(@st)
}

pub fn checksum(st: @GameState) -> felt252 {
    let mut v: Array<felt252> = array![];
    v.append(*st.acc);
    v.append(*st.player.x);
    v.append(*st.player.y);
    v.append((*st.player.angle).into());
    v.append((*st.player.sector).into());
    v.append(*st.player.momx.m);
    v.append((*st.player.momx.neg).into());
    v.append(*st.player.momy.m);
    v.append((*st.player.momy.neg).into());
    v.append((*st.rng).into());
    v.append((*st.tic).into());
    v.append((*st.kills).into());
    v.append((*st.shots).into());
    let src = st.mobjs.span();
    let n = src.len();
    let mut i: u32 = 0;
    while i != n {
        let m = *src.at(i);
        v.append(m.x);
        v.append(m.y);
        v.append(m.angle.into());
        v.append(m.sector.into());
        v.append(m.state.into());
        v.append(m.awake.into());
        v.append(m.movedir.into());
        v.append(m.health.into());
        i += 1;
    }
    poseidon_hash_span(v.span())
}

/// Serialize a mobj into the canonical felt layout used by `checksum`, to
/// measure the felt cost of a ~150-mobj state (CONTEXT section 9).
pub fn mobj_felt_width() -> u32 {
    8
}

/// Full mobj record width when *all* fields are serialized (what `state_hash`
/// would need for an exact replay).
pub fn mobj_full_felt_width() -> u32 {
    17
}

/// Sanity helper used by the tests.
pub fn sector_of(x: felt252, y: felt252) -> u32 {
    let ss = point_in_subsector(x, y, true);
    let s: felt252 = *SS_SECTOR.span().at(ss);
    s.try_into().unwrap()
}
