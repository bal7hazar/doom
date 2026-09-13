// SPDX-License-Identifier: GPL-2.0-only
//! Native ABI probe of the exact prover/sim runner. One space-separated
//! hex-felt request per stdin line; output is `steps <hex output felts...>`.
use std::io::{self, BufRead, Write};
use hellproof_sim::SimProgram;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("executable path required")?;
    let sim = SimProgram::load(&std::fs::read_to_string(path)?)?;
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    for request in io::stdin().lock().lines() {
        let mut input = Vec::new();
        for felt in request?.split_ascii_whitespace() {
            let digits = felt.strip_prefix("0x").unwrap_or(felt);
            if digits.len() > 64 { return Err("felt too wide".into()); }
            let padded = format!("{:0>64}", digits);
            for i in (0..64).step_by(2).rev() { input.push(u8::from_str_radix(&padded[i..i + 2], 16)?); }
        }
        let bytes = sim.run_bytes(&input)?;
        write!(out, "{}", sim.timings().steps as u64)?;
        for felt in bytes.chunks_exact(32) {
            write!(out, " 0x")?;
            for byte in felt.iter().rev() { write!(out, "{byte:02x}")?; }
        }
        writeln!(out)?;
        out.flush()?;
    }
    Ok(())
}
