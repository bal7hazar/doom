// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Hellproof contributors
//! Lower Memory64 SIMD splat loads to equivalent scalar loads + splat.
//! Liftoff in tested V8 versions 13.6/14.1 truncates high addresses in fused loads.
use std::ops::Range;
use wasmparser::{Operator, Parser, Payload, Validator};

fn leb(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let mut b = (n & 127) as u8;
        n >>= 7;
        if n != 0 {
            b |= 128
        }
        out.push(b);
        if n == 0 {
            break;
        }
    }
}
fn read_leb(data: &[u8], pos: &mut usize) -> usize {
    let mut n = 0usize;
    let mut shift = 0;
    loop {
        let b = data[*pos];
        *pos += 1;
        n |= ((b & 127) as usize) << shift;
        if b & 128 == 0 {
            return n;
        }
        shift += 7;
        assert!(shift < 64)
    }
}
fn lower(data: &[u8]) -> Result<(Vec<u8>, usize), Box<dyn std::error::Error>> {
    Validator::new().validate_all(data)?;
    let mut bodies: Vec<(Range<usize>, Vec<u8>)> = vec![];
    let mut total = 0;
    for payload in Parser::new(0).parse_all(data) {
        if let Payload::CodeSectionEntry(body) = payload? {
            let range = body.range();
            let mut reader = body.get_operators_reader()?;
            let mut cursor = range.start;
            let mut bytes = vec![];
            while !reader.eof() {
                let start = reader.original_position();
                let op = reader.read()?;
                let end = reader.original_position();
                let pair = match op {
                    Operator::V128Load8Splat { memarg } => Some((0x2d, 0x0f, memarg)),
                    Operator::V128Load16Splat { memarg } => Some((0x2f, 0x10, memarg)),
                    Operator::V128Load32Splat { memarg } => Some((0x28, 0x11, memarg)),
                    Operator::V128Load64Splat { memarg } => Some((0x29, 0x12, memarg)),
                    _ => None,
                };
                if let Some((scalar, splat, memarg)) = pair {
                    // Current modules contain exactly one Memory64 memory; checked below.
                    assert_eq!(memarg.memory, 0, "multi-memory module unsupported");
                    bytes.extend_from_slice(&data[cursor..start]);
                    bytes.push(scalar);
                    // Preserve the complete memory argument byte for byte (alignment, memory
                    // index and 64-bit offset), including non-canonical but valid LEB encodings.
                    assert_eq!(data[start], 0xfd);
                    let mut memarg_start = start + 1;
                    read_leb(data, &mut memarg_start);
                    bytes.extend_from_slice(&data[memarg_start..end]);
                    bytes.extend_from_slice(&[0xfd, splat]);
                    cursor = end;
                    total += 1;
                }
            }
            bytes.extend_from_slice(&data[cursor..range.end]);
            bodies.push((range, bytes));
        }
    }
    let mut memories = 0;
    for p in Parser::new(0).parse_all(data) {
        match p? {
            Payload::MemorySection(s) => {
                for m in s {
                    let m = m?;
                    assert!(m.memory64, "Memory32 unsupported");
                    memories += 1
                }
            }
            Payload::ImportSection(s) => {
                for i in s {
                    if let wasmparser::TypeRef::Memory(m) = i?.ty {
                        assert!(m.memory64, "Memory32 unsupported");
                        memories += 1
                    }
                }
            }
            _ => {}
        }
    }
    assert_eq!(memories, 1, "requires one Memory64 memory");
    let mut out = data[..8].to_vec();
    let mut pos = 8;
    while pos < data.len() {
        let section_start = pos;
        let id = data[pos];
        pos += 1;
        let len = read_leb(data, &mut pos);
        let end = pos + len;
        if id == 10 {
            out.push(id);
            let mut contents = vec![];
            leb(bodies.len() as u64, &mut contents);
            for (range, body) in &bodies {
                assert!(range.start >= pos && range.end <= end);
                leb(body.len() as u64, &mut contents);
                contents.extend_from_slice(body)
            }
            leb(contents.len() as u64, &mut out);
            out.extend(contents);
        } else {
            out.extend_from_slice(&data[section_start..end])
        }
        pos = end;
    }
    Validator::new().validate_all(&out)?;
    Ok((out, total))
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let a = std::env::args().collect::<Vec<_>>();
    if a.len() != 3 {
        return Err("usage: hellproof-memory64-splats INPUT.wasm OUTPUT.wasm".into());
    }
    let input = std::fs::read(&a[1])?;
    let (output, n) = lower(&input)?;
    std::fs::write(&a[2], &output)?;
    println!(
        "lowered {n} Memory64 SIMD splat loads; {} -> {} bytes",
        input.len(),
        output.len()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn section(id: u8, bytes: &[u8], module: &mut Vec<u8>) {
        module.push(id);
        leb(bytes.len() as u64, module);
        module.extend_from_slice(bytes);
    }

    fn module(opcode: u8, align: u8, offset: u64, imported: bool) -> Vec<u8> {
        let mut module = b"\0asm\x01\0\0\0".to_vec();
        // An unrelated custom section deliberately contains matching opcode bytes.
        section(0, &[1, b'x', 0xfd, opcode, align, 0], &mut module);
        section(1, &[1, 0x60, 1, 0x7e, 1, 0x7b], &mut module);
        if imported {
            // env.memory, shared Memory64, min1/max2 pages.
            section(
                2,
                &[
                    1, 3, b'e', b'n', b'v', 6, b'm', b'e', b'm', b'o', b'r', b'y', 2, 7, 1, 2,
                ],
                &mut module,
            );
        }
        section(3, &[1, 0], &mut module);
        if !imported {
            section(5, &[1, 5, 1, 2], &mut module);
        }
        let mut body = vec![0, 0x20, 0, 0xfd, opcode, align];
        leb(offset, &mut body);
        body.push(0x0b);
        let mut code = vec![1];
        leb(body.len() as u64, &mut code);
        code.extend(body);
        section(10, &code, &mut module);
        module
    }

    #[test]
    fn widths_offsets_alignment_imports_and_idempotence() {
        for (i, opcode) in (7..=10).enumerate() {
            for align in 0..=i as u8 {
                for offset in [0, 7, 1u64 << 32, (1u64 << 48) + 17] {
                    for imported in [false, true] {
                        let input = module(opcode, align, offset, imported);
                        let (output, count) = lower(&input).unwrap();
                        assert_eq!(count, 1);
                        assert_eq!(output.len(), input.len() + 1);
                        let (again, count) = lower(&output).unwrap();
                        assert_eq!(count, 0);
                        assert_eq!(again, output);
                        let mut found = false;
                        for payload in Parser::new(0).parse_all(&output) {
                            if let Payload::CodeSectionEntry(body) = payload.unwrap() {
                                let mut reader = body.get_operators_reader().unwrap();
                                assert!(matches!(
                                    reader.read().unwrap(),
                                    Operator::LocalGet { local_index: 0 }
                                ));
                                let memarg = match (opcode, reader.read().unwrap()) {
                                    (7, Operator::I32Load8U { memarg })
                                    | (8, Operator::I32Load16U { memarg })
                                    | (9, Operator::I32Load { memarg })
                                    | (10, Operator::I64Load { memarg }) => memarg,
                                    _ => panic!("wrong scalar width"),
                                };
                                assert_eq!(memarg.align, align);
                                assert_eq!(memarg.offset, offset);
                                assert_eq!(memarg.memory, 0);
                                assert!(matches!(
                                    (opcode, reader.read().unwrap()),
                                    (7, Operator::I8x16Splat)
                                        | (8, Operator::I16x8Splat)
                                        | (9, Operator::I32x4Splat)
                                        | (10, Operator::I64x2Splat)
                                ));
                                assert!(matches!(reader.read().unwrap(), Operator::End));
                                assert!(reader.eof());
                                found = true;
                            }
                        }
                        assert!(found);
                        // Custom section is untouched, including its embedded fake opcode.
                        assert_eq!(&input[8..16], &output[8..16]);
                    }
                }
            }
        }
    }

    #[test]
    fn rejects_invalid_module() {
        assert!(lower(b"\0asm\x01\0\0\0\x0a\x7f").is_err());
        let mut input = module(9, 2, 0, false);
        input.pop();
        assert!(lower(&input).is_err());
    }
}
