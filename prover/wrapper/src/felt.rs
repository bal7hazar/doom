// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Felts, the Cairo 0 word encoding, and the leaf output digest.
//!
//! This is the Rust twin of `spikes/s4/recursion_outputs/src/{encode,blake,tree}.cairo`: it lets
//! the wrapper check, in microseconds and without any prover, that the `output_preimage` a client
//! submitted really hashes to the output cells its Cairo proof commits to. A mismatch means the
//! leaf would fold into a different digest than the client claims, so the run is rejected before
//! any 32.5 GB job is scheduled.

use anyhow::{bail, Context, Result};
use blake2::{Blake2s256, Digest};

/// A field element as eight little-endian u32 limbs (limb 0 = least significant).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Felt(pub [u32; 8]);

const MSB_U32: u32 = 0x8000_0000;

impl Felt {
    /// Parses a canonical Cairo field element, strictly below 2^251 + 17·2^192 + 1.
    pub fn parse(s: &str) -> Result<Felt> {
        let s = s.trim();
        if s.is_empty() {
            bail!("empty felt");
        }
        let limbs = if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
            parse_hex(hex)?
        } else {
            parse_dec(s)?
        };
        // 252-bit width alone also admits p..2^252-1, which are not field elements.
        const PRIME: [u32; 8] = [1, 0, 0, 0, 0, 0, 17, 0x0800_0000];
        if limbs.iter().rev().cmp(PRIME.iter().rev()) != std::cmp::Ordering::Less {
            bail!("felt out of range: {s}");
        }
        Ok(Felt(limbs))
    }

    pub fn to_hex(self) -> String {
        let mut out = String::from("0x");
        let mut started = false;
        for limb in self.0.iter().rev() {
            if !started && *limb == 0 {
                continue;
            }
            if started {
                out.push_str(&format!("{limb:08x}"));
            } else {
                out.push_str(&format!("{limb:x}"));
                started = true;
            }
        }
        if !started {
            out.push('0');
        }
        out
    }

    /// The Cairo 0 `encode_felt252_data` word encoding (`Blake2Felt252::encode_felts_to_u32s`):
    /// a felt below 2^63 becomes two big-endian words of its low 64 bits, anything else becomes
    /// its eight big-endian words with the MSB of the first set.
    pub fn encode(self, out: &mut Vec<u32>) {
        let v = self.0;
        let small = v[2..].iter().all(|w| *w == 0) && v[1] < MSB_U32;
        if small {
            out.push(v[1]);
            out.push(v[0]);
        } else {
            out.push(v[7].wrapping_add(MSB_U32));
            for i in (0..7).rev() {
                out.push(v[i]);
            }
        }
    }
}

fn parse_hex(hex: &str) -> Result<[u32; 8]> {
    if hex.is_empty() {
        bail!("empty hex felt");
    }
    let hex = hex.trim_start_matches('0');
    if hex.len() > 64 {
        bail!("felt too long");
    }
    let padded = format!("{hex:0>64}");
    let mut limbs = [0u32; 8];
    for (i, chunk) in padded.as_bytes().chunks(8).enumerate() {
        let s = std::str::from_utf8(chunk).unwrap();
        // chunk 0 is the most significant.
        limbs[7 - i] = u32::from_str_radix(s, 16).context("not hex")?;
    }
    Ok(limbs)
}

fn parse_dec(dec: &str) -> Result<[u32; 8]> {
    let mut limbs = [0u32; 8];
    for ch in dec.chars() {
        let d = ch
            .to_digit(10)
            .with_context(|| format!("not a decimal felt: {dec}"))?;
        let mut carry = d as u64;
        for limb in limbs.iter_mut() {
            let v = (*limb as u64) * 10 + carry;
            *limb = v as u32;
            carry = v >> 32;
        }
        if carry != 0 {
            bail!("felt out of range: {dec}");
        }
    }
    Ok(limbs)
}

/// `blake2s(le_bytes(words))`, digest as eight little-endian u32 words — `hash_u32s` of the
/// on-chain verifier and of the `circuits` crate.
pub fn hash_u32s(words: &[u32]) -> [u32; 8] {
    let mut hasher = Blake2s256::new();
    for w in words {
        hasher.update(w.to_le_bytes());
    }
    let digest = hasher.finalize();
    let mut out = [0u32; 8];
    for (i, chunk) in digest.chunks_exact(4).enumerate() {
        out[i] = u32::from_le_bytes(chunk.try_into().unwrap());
    }
    out
}

/// `H1 = blake2s(cairo0_encode(preimage))`: the eight output words of a leaf, the value the
/// recursive tree recomputes from `output_preimage` and the value the leaf's Cairo program wrote
/// into its two output cells.
pub fn leaf_output_words(preimage: &[Felt]) -> [u32; 8] {
    let mut words = Vec::with_capacity(preimage.len() * 8);
    for f in preimage {
        f.encode(&mut words);
    }
    hash_u32s(&words)
}

/// The two 128-bit output cells a leaf program writes, derived from its eight digest words.
/// `leaf_prover` reads them back as `cell[..4]` of each cell's u256 limbs.
pub fn output_cells_from_words(words: &[u32; 8]) -> [Felt; 2] {
    let mut cells = [Felt::default(); 2];
    for (c, chunk) in cells.iter_mut().zip(words.chunks_exact(4)) {
        let mut limbs = [0u32; 8];
        limbs[..4].copy_from_slice(chunk);
        *c = Felt(limbs);
    }
    cells
}

/// The eight digest words carried by two output cells (the inverse of `output_cells_from_words`).
/// Fails if a cell carries anything above 128 bits, which the leaf format forbids.
pub fn words_from_output_cells(cells: &[Felt]) -> Result<[u32; 8]> {
    if cells.len() != 2 {
        bail!(
            "the leaf format requires exactly 2 output cells, got {}",
            cells.len()
        );
    }
    let mut words = [0u32; 8];
    for (i, cell) in cells.iter().enumerate() {
        if cell.0[4..].iter().any(|w| *w != 0) {
            bail!("output cell {i} is larger than 128 bits");
        }
        words[i * 4..(i + 1) * 4].copy_from_slice(&cell.0[..4]);
    }
    Ok(words)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hex_and_decimal_identically() {
        assert_eq!(Felt::parse("0x1f4").unwrap(), Felt::parse("500").unwrap());
        assert_eq!(Felt::parse("0x0").unwrap(), Felt::parse("0").unwrap());
        for s in [
            "0x1",
            "0xff",
            "0x100000000",
            "0x5505b4a58e4ac7a1bbcfd4b1e44cb0f5",
        ] {
            let f = Felt::parse(s).unwrap();
            assert_eq!(f.to_hex(), s, "hex round trip");
            assert_eq!(Felt::parse(&f.to_hex()).unwrap(), f);
        }
    }

    #[test]
    fn rejects_non_felts() {
        assert!(Felt::parse("").is_err());
        assert!(Felt::parse("0xzz").is_err());
        assert!(Felt::parse("12a").is_err());
        // 2^252 has bit 252 set.
        assert!(
            Felt::parse("0x1000000000000000000000000000000000000000000000000000000000000000")
                .is_err()
        );
    }

    #[test]
    fn rejects_prime_and_above_in_both_encodings() {
        let maximum = "0x800000000000011000000000000000000000000000000000000000000000000";
        assert_eq!(Felt::parse(maximum).unwrap().to_hex(), maximum);
        for invalid in [
            "0x",
            "0X",
            "-1",
            "+1",
            "0x800000000000011000000000000000000000000000000000000000000000001",
            "0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "3618502788666131213697322783095070105623107215331596699973092056135872020481",
        ] {
            assert!(Felt::parse(invalid).is_err(), "{invalid}");
        }
        assert_eq!(
            Felt::parse(
                "3618502788666131213697322783095070105623107215331596699973092056135872020480"
            )
            .unwrap(),
            Felt::parse(maximum).unwrap()
        );
    }

    #[test]
    fn encodes_small_felts_as_two_words() {
        let mut out = vec![];
        Felt::parse("0x1").unwrap().encode(&mut out);
        assert_eq!(out, vec![0, 1]);
        out.clear();
        Felt::parse("0xfa").unwrap().encode(&mut out);
        assert_eq!(out, vec![0, 0xfa]);
    }

    #[test]
    fn encodes_large_felts_as_eight_words_with_msb() {
        let mut out = vec![];
        // 2^63: no longer "small" (bit 63 set means limb 1 >= 0x80000000).
        Felt::parse("0x8000000000000000").unwrap().encode(&mut out);
        assert_eq!(out, vec![MSB_U32, 0, 0, 0, 0, 0, 0x8000_0000, 0]);
    }

    /// RFC 7693 test vector: blake2s of the empty message.
    #[test]
    fn blake2s_empty() {
        let words = hash_u32s(&[]);
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        assert_eq!(
            hex::encode(bytes),
            "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"
        );
    }

    #[test]
    fn output_cells_round_trip() {
        let words = [1u32, 2, 3, 4, 5, 6, 7, 8];
        let cells = output_cells_from_words(&words);
        assert_eq!(words_from_output_cells(&cells).unwrap(), words);
    }
}
