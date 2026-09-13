// SPDX-License-Identifier: GPL-2.0-only
//! For every Sierra statement of a Scarb `*.sierra.json`, the CASM offset
//! range it compiles to: one `idx start end` line per statement, then a
//! `TOTAL <code words>` line. The program is compiled exactly as
//! `cairo-execute` compiles an executable with `enable-gas = false`
//! (ap-change-only metadata, no gas check), so the offsets are the ones of
//! the `*.executable.json` bytecode, shifted by the executable header.
use cairo_lang_sierra::program::VersionedProgram;
use cairo_lang_sierra_to_casm::compiler::{compile, SierraToCasmConfig};
use cairo_lang_sierra_to_casm::metadata::calc_metadata_ap_change_only;
use cairo_lang_sierra_type_size::ProgramRegistryInfo;

fn main() {
    let path = std::env::args().nth(1).expect("usage: sierra_words <file.sierra.json>");
    let text = std::fs::read_to_string(&path).expect("read");
    let versioned: VersionedProgram = serde_json::from_str(&text).expect("parse");
    let program = versioned.into_v1().expect("v1").program;
    let info = ProgramRegistryInfo::new(&program).expect("registry");
    let metadata = calc_metadata_ap_change_only(&program, &info).expect("metadata");
    let config = SierraToCasmConfig { gas_usage_check: false, max_bytecode_size: usize::MAX };
    let cairo_program = compile(&program, &info, &metadata, config).expect("compile");
    let mut total = 0usize;
    for (i, info) in cairo_program.debug_info.sierra_statement_info.iter().enumerate() {
        println!("{} {} {}", i, info.start_offset, info.end_offset);
        if info.end_offset > total {
            total = info.end_offset;
        }
    }
    println!("TOTAL {}", total);
}
