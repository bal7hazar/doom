// SPDX-License-Identifier: GPL-2.0-only
//! Private executable adapter: the standard `[length, felts...]` ABI.
//! Input spans use core's checked zero-copy decoder; output copies in
//! fixed-size blocks to avoid one generic Serde call per felt. Game-state
//! validation remains in `doom_game::from_felts`.

#[derive(Copy, Drop)]
pub(crate) struct Felts {
    data: Span<felt252>,
}

pub(crate) fn felts(data: Span<felt252>) -> Felts {
    Felts { data }
}

pub(crate) impl FeltsSerde of Serde<Felts> {
    fn serialize(self: @Felts, ref output: Array<felt252>) {
        output.append((*self.data).len().into());
        append(ref output, *self.data);
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<Felts> {
        let data: Span<felt252> = Serde::deserialize(ref serialized)?;
        Option::Some(Felts { data })
    }
}

fn append(ref output: Array<felt252>, mut data: Span<felt252>) {
    while let Option::Some(block) = data.multi_pop_front::<64>() {
        append_block(ref output, block);
    }
    while let Option::Some(value) = data.pop_front() {
        output.append(*value);
    }
}

#[inline(always)]
fn append_block(ref output: Array<felt252>, block: @Box<[felt252; 64]>) {
    let [
        f0,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
        f13,
        f14,
        f15,
        f16,
        f17,
        f18,
        f19,
        f20,
        f21,
        f22,
        f23,
        f24,
        f25,
        f26,
        f27,
        f28,
        f29,
        f30,
        f31,
        f32,
        f33,
        f34,
        f35,
        f36,
        f37,
        f38,
        f39,
        f40,
        f41,
        f42,
        f43,
        f44,
        f45,
        f46,
        f47,
        f48,
        f49,
        f50,
        f51,
        f52,
        f53,
        f54,
        f55,
        f56,
        f57,
        f58,
        f59,
        f60,
        f61,
        f62,
        f63,
    ] =
        block
        .unbox();
    output.append(f0);
    output.append(f1);
    output.append(f2);
    output.append(f3);
    output.append(f4);
    output.append(f5);
    output.append(f6);
    output.append(f7);
    output.append(f8);
    output.append(f9);
    output.append(f10);
    output.append(f11);
    output.append(f12);
    output.append(f13);
    output.append(f14);
    output.append(f15);
    output.append(f16);
    output.append(f17);
    output.append(f18);
    output.append(f19);
    output.append(f20);
    output.append(f21);
    output.append(f22);
    output.append(f23);
    output.append(f24);
    output.append(f25);
    output.append(f26);
    output.append(f27);
    output.append(f28);
    output.append(f29);
    output.append(f30);
    output.append(f31);
    output.append(f32);
    output.append(f33);
    output.append(f34);
    output.append(f35);
    output.append(f36);
    output.append(f37);
    output.append(f38);
    output.append(f39);
    output.append(f40);
    output.append(f41);
    output.append(f42);
    output.append(f43);
    output.append(f44);
    output.append(f45);
    output.append(f46);
    output.append(f47);
    output.append(f48);
    output.append(f49);
    output.append(f50);
    output.append(f51);
    output.append(f52);
    output.append(f53);
    output.append(f54);
    output.append(f55);
    output.append(f56);
    output.append(f57);
    output.append(f58);
    output.append(f59);
    output.append(f60);
    output.append(f61);
    output.append(f62);
    output.append(f63);
}

#[cfg(test)]
mod tests {
    use super::felts;

    fn compare(input: Span<felt252>) {
        let array: Array<felt252> = input.into();
        let mut expected = array![];
        array.serialize(ref expected);
        let mut actual = array![];
        felts(input).serialize(ref actual);
        assert(actual == expected, 'identical length-prefixed ABI');
        let mut encoded = actual.span();
        let decoded: Span<felt252> = Serde::deserialize(ref encoded).expect('checked span');
        assert(decoded == input && encoded.is_empty(), 'checked complete input');
    }

    #[test]
    fn test_wire_block_boundaries() {
        let sizes: Array<u32> = array![
            0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257,
        ];
        for n in sizes {
            let mut values = array![];
            let mut i = 0;
            while i < n {
                values.append(i.into() * 0x100000000 + 17);
                i += 1;
            }
            compare(values.span());
        }
    }

    #[test]
    fn test_wire_complete_game_state_and_snapshot() {
        let game = doom_game::genesis(doom_map::LevelId::E1M1);
        compare(doom_game::serialize(@game).span());
        compare(doom_game::snapshot(@game).span());
    }

    #[test]
    fn test_span_decoder_rejects_same_malformed_lengths() {
        let cases = array![
            array![].span(), array![1].span(), array![3, 1, 2].span(),
            array![0x100000000, 1].span(),
        ];
        for input in cases {
            let mut old = input;
            let mut new = input;
            let a: Option<Array<felt252>> = Serde::deserialize(ref old);
            let b: Option<Span<felt252>> = Serde::deserialize(ref new);
            assert(a.is_none() && b.is_none(), 'malformed length rejected');
        }
    }
}
