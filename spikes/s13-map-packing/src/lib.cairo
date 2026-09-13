// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: GPL-2.0-only
//! Isolated experiment. No production loader or state depends on this crate.
mod data;

/// Decode exactly `count` eleven-bit ids, six per word, with canonical padding.
/// Bounded metadata, exact input length and no unused high bits are required.
#[inline(never)]
fn decode(mut packed: Span<u128>, count: u32) -> Option<Span<u32>> {
    if count > 2064 || packed.len() != (count + 5) / 6 {
        return Option::None;
    }
    let mut remaining = count;
    let mut output: Array<u32> = array![];
    let radix: NonZero<u128> = 2048;
    while let Option::Some(word) = packed.pop_front() {
        let mut value = *word;
        let mut slots = if remaining < 6 {
            remaining
        } else {
            6
        };
        remaining = remaining - slots;
        while slots != 0 {
            let (rest, id) = DivRem::div_rem(value, radix);
            let id: u32 = id.try_into()?;
            output.append(id);
            value = rest;
            slots = slots - 1;
        }
        if value != 0 {
            return Option::None;
        }
    }
    Option::Some(output.span())
}

/// Runtime opaque count must match the public table length.
#[executable]
fn reference(count: u32) -> Option<Span<u32>> {
    if count == 2064 {
        Option::Some(data::BM_ITEMS.span())
    } else {
        Option::None
    }
}

#[executable]
fn candidate(count: u32) -> Option<Span<u32>> {
    if count == 2064 {
        decode(data::BM_ITEMS_PACKED.span(), count)
    } else {
        Option::None
    }
}

/// Opaque values exercise masks, partial groups and malformed padding separately.
#[executable]
fn inspect_decode(packed: Span<u128>, count: u32) -> Option<Span<u32>> {
    decode(packed, count)
}
