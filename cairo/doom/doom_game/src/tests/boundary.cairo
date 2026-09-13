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
    let mut mobjs: Array<Mobj> = g.mobjs.into();
    let repeated = *g.mobjs.at(0);
    while mobjs.len() < doom_physics::MAX_MOBJS {
        mobjs.append(repeated);
    }
    g.mobjs = mobjs.span();
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
