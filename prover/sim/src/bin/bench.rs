// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Native benchmark, running exactly the same code path as the wasm build.
//!
//! ```text
//! hellproof-sim-bench --executable <path.executable.json> [options]
//!   --state-len N     number of state felts (default 1500)
//!   --iters N         sustained-throughput iterations (default 2000)
//!   --leak-iters N    iterations for the allocation-growth check (default 10000)
//!   --skip-naive      do not measure the re-parse-per-call alternative
//!   --inflate N       append N dead bytecode words to the executable JSON,
//!                     to see how the one-off parse scales with program size
//!   --naive-iters N   iterations of the naive alternative (default 20)
//!   --json            emit a JSON report on stdout
//! ```

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

use cairo_vm::Felt252;
use hellproof_sim::core::{self, RunMode, SimProgram};

/// Tracks the number of bytes currently handed out by the allocator, so the
/// native run can answer the same "does it leak?" question as the browser run.
struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        System.dealloc(ptr, layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LIVE.fetch_add(new_size, Ordering::Relaxed);
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

fn live_bytes() -> usize {
    LIVE.load(Ordering::Relaxed)
}

struct Args {
    executable: String,
    state_len: usize,
    iters: usize,
    leak_iters: usize,
    naive_iters: usize,
    skip_naive: bool,
    json: bool,
    inflate: usize,
}

/// Append `extra` dead bytecode words to the executable JSON.
///
/// The benchmark program is a 4 kB executable; a real `step_tic` will be
/// hundreds of kilobytes. Inflating the bytecode is the cheapest way to see
/// how the one-off parse — and therefore the per-call cost of the naive
/// re-parse-every-tic alternative — scales with program size. The appended
/// words sit past the `ret` of the entry code and are never executed.
fn inflate_executable(json_text: &str, extra: usize) -> String {
    let mut value: serde_json::Value = serde_json::from_str(json_text).expect("bad executable");
    let bytecode = value["program"]["bytecode"]
        .as_array_mut()
        .expect("no bytecode array");
    for i in 0..extra {
        bytecode.push(serde_json::Value::String(format!("0x{:x}", i % 1024 + 1)));
    }
    serde_json::to_string(&value).expect("reserialize")
}

fn parse_args() -> Args {
    let mut args = Args {
        executable: String::new(),
        state_len: 1500,
        iters: 2000,
        leak_iters: 10_000,
        naive_iters: 20,
        skip_naive: false,
        json: false,
        inflate: 0,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--executable" => args.executable = it.next().expect("--executable needs a path"),
            "--state-len" => args.state_len = it.next().unwrap().parse().unwrap(),
            "--iters" => args.iters = it.next().unwrap().parse().unwrap(),
            "--leak-iters" => args.leak_iters = it.next().unwrap().parse().unwrap(),
            "--naive-iters" => args.naive_iters = it.next().unwrap().parse().unwrap(),
            "--skip-naive" => args.skip_naive = true,
            "--inflate" => args.inflate = it.next().unwrap().parse().unwrap(),
            "--json" => args.json = true,
            other => panic!("unknown flag {other}"),
        }
    }
    assert!(!args.executable.is_empty(), "--executable is required");
    args
}

/// `[state_len, s0, .., s_{n-1}, cmd]`, the Cairo serialization of
/// `(state: Array<felt252>, cmd: felt252)`.
fn make_args(state_len: usize, tic: u64) -> Vec<Felt252> {
    let mut v = Vec::with_capacity(state_len + 2);
    v.push(Felt252::from(state_len as u64));
    for i in 0..state_len {
        v.push(Felt252::from((i as u64).wrapping_mul(2_654_435_761) ^ tic));
    }
    v.push(Felt252::from(tic % 8));
    v
}

/// FNV-1a over the raw output bytes of `tics` consecutive calls: the same
/// value the JS benchmark computes, so the three environments can be compared
/// bit for bit (groundwork for R5-A3).
fn output_fingerprint(program: &SimProgram, state_len: usize, tics: u64) -> u32 {
    let mut hash: u32 = 0x811c_9dc5;
    for tic in 0..tics {
        let bytes = core::encode_felts(&make_args(state_len, tic));
        let out = program.run_bytes(&bytes).expect("fingerprint run failed");
        for byte in &out {
            hash ^= u32::from(*byte);
            hash = hash.wrapping_mul(0x0100_0193);
        }
    }
    hash
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * p).round() as usize;
    sorted[idx]
}

fn main() {
    let args = parse_args();
    let json_text = {
        let text = std::fs::read_to_string(&args.executable).expect("cannot read the executable");
        if args.inflate > 0 {
            inflate_executable(&text, args.inflate)
        } else {
            text
        }
    };

    // --- first-call latency: parse + first run -------------------------------
    let live_before_load = live_bytes();
    let t0 = hellproof_sim::clock::now_ms();
    let program = SimProgram::load(&json_text).expect("load failed");
    let t_load = hellproof_sim::clock::now_ms() - t0;
    let live_after_load = live_bytes();

    let call_args = make_args(args.state_len, 0);
    let t1 = hellproof_sim::clock::now_ms();
    let first = program.run_felts(&call_args).expect("first run failed");
    let t_first_run = hellproof_sim::clock::now_ms() - t1;
    let steps = program.timings().steps;
    if std::env::var("HELLPROOF_DUMP").is_ok() {
        eprintln!("raw output len = {}", first.len());
        for (i, f) in first.iter().take(6).enumerate() {
            eprintln!("  raw[{i}] = {f:#x}");
        }
        for (i, f) in first.iter().enumerate().skip(first.len().saturating_sub(3)) {
            eprintln!("  raw[{i}] = {f:#x}");
        }
    }
    let out_len = core::array_body(&first).expect("bad output").len();
    let fingerprint = output_fingerprint(&program, args.state_len, 100);

    // --- sustained throughput ------------------------------------------------
    let mut per_call = Vec::with_capacity(args.iters);
    let mut sum = core::Timings::default();
    let mut checksum = Felt252::ZERO;
    let live_before_loop = live_bytes();
    let loop_start = hellproof_sim::clock::now_ms();
    for i in 0..args.iters {
        let a = make_args(args.state_len, i as u64);
        let bytes = core::encode_felts(&a);
        let t = hellproof_sim::clock::now_ms();
        let out = program.run_bytes(&bytes).expect("run failed");
        per_call.push(hellproof_sim::clock::now_ms() - t);
        let tm = program.timings();
        sum.decode_args += tm.decode_args;
        sum.init += tm.init;
        sum.run += tm.run;
        sum.read_output += tm.read_output;
        sum.encode_output += tm.encode_output;
        checksum += Felt252::from(out.len() as u64);
    }
    let loop_ms = hellproof_sim::clock::now_ms() - loop_start;
    let live_after_loop = live_bytes();
    per_call.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = args.iters as f64;

    // --- proof-shape comparison ---------------------------------------------
    let proof_program = SimProgram::load_with_mode(&json_text, RunMode::ProofShapeNoTrace)
        .expect("proof-shape load failed");
    let proof_iters = args.iters.min(200);
    let t = hellproof_sim::clock::now_ms();
    for i in 0..proof_iters {
        proof_program
            .run_felts(&make_args(args.state_len, i as u64))
            .expect("proof-shape run failed");
    }
    let proof_ms = (hellproof_sim::clock::now_ms() - t) / proof_iters as f64;

    // --- fresh hint processor per call (no processor reuse) ------------------
    let fresh_iters = args.iters.min(200);
    let t = hellproof_sim::clock::now_ms();
    for i in 0..fresh_iters {
        let mut hp = program.fresh_hint_processor();
        program
            .run_felts_with(&mut hp, &make_args(args.state_len, i as u64))
            .expect("fresh-processor run failed");
    }
    let fresh_ms = (hellproof_sim::clock::now_ms() - t) / fresh_iters as f64;

    // --- naive: re-parse the executable JSON on every call -------------------
    let naive_ms = if args.skip_naive {
        f64::NAN
    } else {
        // Exactly the cached loop above, plus the parse: same `run_bytes`
        // entry point, same arguments, so the difference is the parse alone.
        let bytes = core::encode_felts(&make_args(args.state_len, 1));
        let t = hellproof_sim::clock::now_ms();
        for _ in 0..args.naive_iters {
            let p = SimProgram::load(&json_text).expect("naive load failed");
            p.run_bytes(&bytes).expect("naive run failed");
        }
        (hellproof_sim::clock::now_ms() - t) / args.naive_iters as f64
    };

    // --- allocation growth ---------------------------------------------------
    let live_leak_start = live_bytes();
    for i in 0..args.leak_iters {
        program
            .run_felts(&make_args(args.state_len, i as u64))
            .expect("leak-loop run failed");
    }
    let live_leak_end = live_bytes();

    let report = format!(
        r#"{{
  "environment": "native",
  "executable": "{exe}",
  "state_len": {state_len},
  "executable_json_bytes": {json_bytes},
  "inflate_words": {inflate},
  "steps_per_call": {steps},
  "output_felts": {out_len},
  "output_fingerprint": {fingerprint},
  "iters": {iters},
  "load_ms": {load_ms:.3},
  "first_run_ms": {first_run_ms:.3},
  "load_bytes": {load_bytes},
  "mean_ms": {mean:.4},
  "p50_ms": {p50:.4},
  "p95_ms": {p95:.4},
  "p99_ms": {p99:.4},
  "max_ms": {max:.4},
  "tics_per_s": {tps:.1},
  "breakdown_ms": {{
    "decode_args": {decode:.4},
    "runner_init": {init:.4},
    "vm_run": {run:.4},
    "read_output": {read:.4},
    "encode_output": {encode:.4}
  }},
  "proof_shape_ms": {proof_ms:.4},
  "fresh_processor_ms": {fresh_ms:.4},
  "naive_reparse_ms": {naive_ms:.4},
  "live_bytes": {{
    "before_load": {lb0},
    "after_load": {lb1},
    "before_loop": {lb2},
    "after_loop": {lb3},
    "leak_start": {lb4},
    "leak_end": {lb5},
    "leak_iters": {leak_iters}
  }},
  "checksum": "{checksum}"
}}"#,
        exe = args.executable,
        state_len = args.state_len,
        json_bytes = json_text.len(),
        inflate = args.inflate,
        steps = steps as u64,
        out_len = out_len,
        fingerprint = fingerprint,
        iters = args.iters,
        load_ms = t_load,
        first_run_ms = t_first_run,
        load_bytes = live_after_load.saturating_sub(live_before_load),
        mean = loop_ms / n,
        p50 = percentile(&per_call, 0.50),
        p95 = percentile(&per_call, 0.95),
        p99 = percentile(&per_call, 0.99),
        max = per_call.last().copied().unwrap_or(0.0),
        tps = 1000.0 * n / loop_ms,
        decode = sum.decode_args / n,
        init = sum.init / n,
        run = sum.run / n,
        read = sum.read_output / n,
        encode = sum.encode_output / n,
        proof_ms = proof_ms,
        fresh_ms = fresh_ms,
        naive_ms = naive_ms,
        lb0 = live_before_load,
        lb1 = live_after_load,
        lb2 = live_before_loop,
        lb3 = live_after_loop,
        lb4 = live_leak_start,
        lb5 = live_leak_end,
        leak_iters = args.leak_iters,
        checksum = checksum,
    );

    if args.json {
        println!("{report}");
    } else {
        eprintln!("{report}");
        println!(
            "native: {:.1} tics/s ({} steps/tic, {:.3} ms/tic, p99 {:.3} ms)",
            1000.0 * n / loop_ms,
            steps as u64,
            loop_ms / n,
            percentile(&per_call, 0.99),
        );
    }
}
