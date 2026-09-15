// SPDX-License-Identifier: GPL-2.0-only
//! Boundary-only regression tests: record validation and exact grid order.
use doom_map::LevelId;
use doom_physics::Mobj;
use crate::{from_felts, genesis, serialize};

fn altered(input: Span<felt252>, at: u32, value: felt252) -> Array<felt252> {
    let mut out = array![];
    let mut i = 0;
    for f in input {
        out.append(if i == at {
            value
        } else {
            *f
        });
        i += 1;
    }
    out
}

#[test]
fn test_record_block_keeps_every_field_domain_check() {
    let g = genesis(LevelId::E1M1);
    let state = serialize(@g);
    // Header(3), scalar/player/count prefix(44), then 27-felt records.
    let fixed = array![1, 2, 3, 5, 6, 7, 8, 9, 22, 23];
    for field in fixed {
        assert(
            from_felts(altered(state.span(), 47 + field, 0x200000000).span()).is_none(),
            'fixed domain',
        );
    }
    let integers = array![0, 4, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 24, 25];
    for field in integers {
        assert(
            from_felts(altered(state.span(), 47 + field, 0x100000000).span()).is_none(),
            'u32 domain',
        );
    }
    assert(
        from_felts(altered(state.span(), 47 + 11, 0x200000000).span()).is_none(), 'signed health',
    );
    assert(from_felts(altered(state.span(), 47 + 26, 2).span()).is_none(), 'boolean domain');
}

#[test]
fn test_truncated_record_block_is_rejected() {
    let state = serialize(@genesis(LevelId::E1M1));
    let mut n = 47;
    while n < 74 {
        let short = state.span().slice(0, n);
        let encoded = altered(short, 2, (n - 3).into());
        assert(from_felts(encoded.span()).is_none(), 'short mobj rejected');
        n += 1;
    }
}

#[test]
fn test_grid_member_bits_cover_all_256_slots() {
    let mut g = genesis(LevelId::E1M1);
    let mut mobjs: Array<core::box::Box<Mobj>> = g.mobjs.into();
    let repeated = g.mobjs.at(0).unbox();
    while mobjs.len() < doom_physics::MAX_MOBJS {
        mobjs.append(BoxTrait::new(repeated));
    }
    g.mobjs = mobjs.span();
    g.actors = doom_monsters::actors::scan(g.mobjs);
    g.grid = doom_physics::grid::rebuild(g.mobjs);
    let encoded = serialize(@g);
    let restored = from_felts(encoded.span()).expect('all 256 members');
    assert(serialize(@restored) == encoded, 'same full grid order');
}

#[test]
fn test_grid_duplicate_member_is_rejected() {
    let g = genesis(LevelId::E1M1);
    let state = serialize(@g);
    let nm: u32 = (*state.at(46)).try_into().unwrap();
    let ns_at = 47 + nm * 27;
    let ns: u32 = (*state.at(ns_at)).try_into().unwrap();
    let mut pos = ns_at + 2 + ns;
    let mut found = false;
    while pos < state.len() {
        let count: u32 = (*state.at(pos + 1)).try_into().unwrap();
        if count > 1 {
            let duplicate = altered(state.span(), pos + 3, *state.at(pos + 2));
            assert(from_felts(duplicate.span()).is_none(), 'duplicate member');
            found = true;
            break;
        }
        pos += 2 + count;
    }
    assert(found, 'fixture has a multi-member cell');
}

#[test]
fn test_player_block_preserves_every_scalar_domain_check() {
    let state = serialize(@genesis(LevelId::E1M1));
    // The 36 player fields start after three header and seven scalar felts.
    for field in array![15, 16, 17, 18, 21, 22] {
        assert(
            from_felts(altered(state.span(), 10 + field, 0x200000000).span()).is_none(),
            'player fixed',
        );
    }
    for field in array![9, 29, 30] {
        assert(from_felts(altered(state.span(), 10 + field, 2).span()).is_none(), 'player boolean');
    }
    for field in array![
        0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 19, 20, 23, 24, 25, 26, 27, 28, 31, 32, 33,
        34, 35,
    ] {
        assert(
            from_felts(altered(state.span(), 10 + field, 0x100000000).span()).is_none(),
            'player u32',
        );
    }
}

#[test]
fn test_truncated_player_block_is_rejected() {
    let state = serialize(@genesis(LevelId::E1M1));
    let mut n = 10;
    while n < 46 {
        let short = altered(state.span().slice(0, n), 2, (n - 3).into());
        assert(from_felts(short.span()).is_none(), 'short player');
        n += 1;
    }
}

#[test]
fn test_specials_blocks_preserve_their_field_domains() {
    let mut g = genesis(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1);
    let mover = doom_specials::Mover {
        kind: doom_specials::MoverKind::DoorNormal,
        phase: doom_specials::Phase::Up,
        sector: *lm.ceil_sectors.at(0),
        height: fixed::ZERO,
        top: fixed::from_int(1),
        bottom: fixed::ZERO,
        count: 7,
    };
    g.specials.movers = array![mover].span();
    let state = serialize(@g);
    let restored = from_felts(state.span()).expect('valid distinct fields');
    assert(serialize(@restored) == state, 'exact specials fields');
    let light = 47
        + g.mobjs.len() * 27
        + 1
        + 3
        + lm.ceil_sectors.len()
        + lm.floor_sectors.len()
        + lm.special_sectors.len()
        + 1;
    assert(from_felts(altered(state.span(), light, 2).span()).is_none(), 'light kind');
    let mut i = 1;
    while i < 8 {
        assert(
            from_felts(altered(state.span(), light + i, 0x100000000).span()).is_none(), 'light u32',
        );
        i += 1;
    }
    let mv = light + g.specials.lights.len() * 8 + 1;
    assert(from_felts(altered(state.span(), mv, 5).span()).is_none(), 'mover kind');
    assert(from_felts(altered(state.span(), mv + 1, 3).span()).is_none(), 'mover phase');
    for field in array![2, 6] {
        assert(
            from_felts(altered(state.span(), mv + field, 0x100000000).span()).is_none(),
            'mover u32',
        );
    }
    for field in array![3, 4, 5] {
        assert(
            from_felts(altered(state.span(), mv + field, 0x200000000).span()).is_none(),
            'mover fixed',
        );
    }
    for size in array![7, 6] {
        let at = if size == 7 {
            light
        } else {
            mv
        };
        let mut n = 0;
        while n <= size {
            let end = at + n;
            let short = altered(state.span().slice(0, end), 2, (end - 3).into());
            assert(from_felts(short.span()).is_none(), 'short specials');
            n += 1;
        }
    }
}
