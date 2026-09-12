//! Mobj state and the tuning knobs the spike measures.

use crate::fixed::Sf;

pub const ST_SPAWN: u32 = 0;
pub const ST_SEE: u32 = 1;
pub const ST_MELEE: u32 = 2;
pub const ST_MISSILE: u32 = 3;

pub const PLAYER_RADIUS: felt252 = 1048576; // 16 << 16
pub const MONSTER_RADIUS: felt252 = 1310720; // 20 << 16
pub const MONSTER_SPEED: felt252 = 524288; //  8 << 16
pub const MELEE_RANGE: felt252 = 4194304; // 64 << 16
pub const MISSILE_RANGE: felt252 = 67108864; // 1024 << 16
pub const MAX_STEP: felt252 = 1572864; // 24 << 16
pub const MOBJ_HEIGHT: felt252 = 3670016; // 56 << 16
pub const SHOT_RANGE: felt252 = 134217728; // 2048 << 16

#[derive(Copy, Drop)]
pub struct Mobj {
    pub x: felt252,
    pub y: felt252,
    pub momx: Sf,
    pub momy: Sf,
    pub angle: u32,
    pub sector: u32,
    pub floorz: felt252,
    pub health: u32,
    pub state: u32,
    pub tics: u32,
    pub movedir: u32,
    pub movecount: u32,
    pub threshold: u32,
    pub awake: u32,
    pub sight_ok: u32,
    pub sight_tic: u32,
    pub id: u32,
}

/// Which optimisations are enabled, so each can be priced separately.
#[derive(Copy, Drop)]
pub struct Opts {
    /// R2-A2: consult the REJECT table before any sight traversal.
    pub reject: bool,
    /// R2-A3: dormant monsters look 1 tic in 4; sight result cached for
    /// `threshold` tics once awake.
    pub cadence: bool,
    /// R2-A4: 3-array half-plane form with the bias term hoisted.
    pub three: bool,
    /// R2-A5: deduplicate blockmap line lists across the cells of a bbox.
    pub dedup: bool,
    /// Doom's per-line bbox reject before the half-plane test.
    pub bboxreject: bool,
    /// Skip the BSP descent when the blockmap cell contains no linedef and
    /// therefore lies entirely inside one sector.
    pub fastsector: bool,
}

pub fn opts_from(
    reject: u32, cadence: u32, three: u32, dedup: u32, bboxreject: u32, fastsector: u32,
) -> Opts {
    Opts {
        reject: reject != 0,
        cadence: cadence != 0,
        three: three != 0,
        dedup: dedup != 0,
        bboxreject: bboxreject != 0,
        fastsector: fastsector != 0,
    }
}
