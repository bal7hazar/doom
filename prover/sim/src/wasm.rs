// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! wasm-bindgen surface.
//!
//! ## Felt encoding (no JSON on the hot path)
//!
//! Every felt crossing the JS/wasm boundary is a **fixed 32-byte
//! little-endian** value: felt `i` occupies bytes `[32*i, 32*i+32)` of the
//! `Uint8Array`, least significant byte first, zero-padded, and must be
//! canonical (`< p`, the STARK prime). A 1 500-felt state is therefore exactly
//! 48 000 bytes.
//!
//! Arguments are the **Cairo-serialized** parameters of the entrypoint, i.e.
//! exactly what `scarb execute --arguments` takes: for
//! `fn step_tic(state: Array<felt252>, cmd: felt252)` that is
//! `[1500, s0, .., s1499, cmd]`.
//!
//! `run` returns the Cairo serialization of the return value, which is
//! exactly the content of the output builtin segment: for
//! `-> Array<felt252>` that is `[len, e0, .., e_{len-1}]`. A Cairo panic is
//! reported as an error, never as a value.
//!
//! ## Zero-copy path
//!
//! `run` copies the arguments in and the results out (wasm-bindgen allocates a
//! `Vec<u8>` per direction). To avoid both copies, JS can write the arguments
//! straight into wasm linear memory:
//!
//! ```js
//! const p = sim.reserve_input(1501);                       // -> byte offset
//! new Uint8Array(wasm.memory.buffer, p, 1501 * 32).set(argBytes);
//! const n = sim.run_buffered(1501);                        // -> felts written
//! const out = new Uint8Array(wasm.memory.buffer, sim.output_ptr(), n * 32);
//! ```
//!
//! Beware: any wasm allocation may grow the memory and detach previous views,
//! so the views must be rebuilt after each call (they are, above).

use wasm_bindgen::prelude::*;

use crate::core::{self, FELT_BYTES};

#[wasm_bindgen(js_name = SimProgram)]
pub struct JsSimProgram {
    inner: core::SimProgram,
    input: Vec<u8>,
    output: Vec<u8>,
}

#[wasm_bindgen(js_class = SimProgram)]
impl JsSimProgram {
    /// Parse a Scarb `.executable.json` **once**. Everything reusable across
    /// calls (bytecode, hints dictionary, hint-string map, hint processor) is
    /// cached in the returned object.
    pub fn load(executable_json: &str) -> Result<JsSimProgram, JsError> {
        let inner = core::SimProgram::load(executable_json).map_err(to_js)?;
        Ok(JsSimProgram {
            inner,
            input: Vec::new(),
            output: Vec::new(),
        })
    }

    /// Same, but running the proof-mode entrypoint (trace still disabled).
    pub fn load_proof_shape(executable_json: &str) -> Result<JsSimProgram, JsError> {
        let inner =
            core::SimProgram::load_with_mode(executable_json, core::RunMode::ProofShapeNoTrace)
                .map_err(to_js)?;
        Ok(JsSimProgram {
            inner,
            input: Vec::new(),
            output: Vec::new(),
        })
    }

    /// Execute one tic. `args` is the little-endian felt buffer described
    /// above; the result is the returned `Array<felt252>` in the same encoding.
    pub fn run(&mut self, args: &[u8]) -> Result<Vec<u8>, JsError> {
        let felts = core::decode_felts(args).map_err(to_js)?;
        let raw = self.inner.run_felts(&felts).map_err(to_js)?;
        Ok(core::encode_felts(&raw))
    }

    /// Same, but taking the little-endian argument buffer directly and
    /// recording the encode/decode timings (see `last_timings`).
    pub fn run_timed(&mut self, args: &[u8]) -> Result<Vec<u8>, JsError> {
        self.inner.run_bytes(args).map_err(to_js)
    }

    /// Debug helper: arguments and results as JSON arrays of decimal strings.
    /// Never use it on the hot path.
    pub fn run_json(&mut self, args_json: &str) -> Result<String, JsError> {
        let args: Vec<String> = serde_json::from_str(args_json)
            .map_err(|e| JsError::new(&format!("bad args JSON: {e}")))?;
        let felts = args
            .iter()
            .map(|s| parse_felt(s))
            .collect::<Result<Vec<_>, _>>()?;
        let raw = self.inner.run_felts(&felts).map_err(to_js)?;
        let out: Vec<String> = raw.iter().map(|f| f.to_string()).collect();
        serde_json::to_string(&out).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Reserve room for `n_felts` arguments in wasm memory and return the byte
    /// offset JS must write to.
    pub fn reserve_input(&mut self, n_felts: usize) -> *const u8 {
        self.input.clear();
        self.input.resize(n_felts * FELT_BYTES, 0);
        self.input.as_ptr()
    }

    /// Byte offset of the output buffer filled by [`JsSimProgram::run_buffered`].
    pub fn output_ptr(&self) -> *const u8 {
        self.output.as_ptr()
    }

    /// Run on the `n_felts` arguments previously written at `reserve_input`,
    /// leave the results in the output buffer and return their count in felts.
    /// No JS/wasm copy at all.
    pub fn run_buffered(&mut self, n_felts: usize) -> Result<usize, JsError> {
        let args = core::decode_felts(&self.input[..n_felts * FELT_BYTES]).map_err(to_js)?;
        let raw = self.inner.run_felts(&args).map_err(to_js)?;
        self.output.clear();
        self.output.resize(raw.len() * FELT_BYTES, 0);
        for (i, felt) in raw.iter().enumerate() {
            self.output[i * FELT_BYTES..(i + 1) * FELT_BYTES].copy_from_slice(&felt.to_bytes_le());
        }
        Ok(raw.len())
    }

    /// Breakdown of the last call, in milliseconds:
    /// `[decode_args, runner_init, vm_run, read_output, encode_output, steps]`.
    pub fn last_timings(&self) -> Vec<f64> {
        self.inner.timings().as_array().to_vec()
    }

    /// Number of Cairo steps executed by the last call.
    pub fn last_steps(&self) -> f64 {
        self.inner.timings().steps
    }
}

/// The naive alternative: parse the executable JSON on **every** call, the way
/// `stwo-cairo`'s `execute` entry point does. Only there to be measured.
#[wasm_bindgen]
pub fn run_once_from_json(executable_json: &str, args: &[u8]) -> Result<Vec<u8>, JsError> {
    let program = core::SimProgram::load(executable_json).map_err(to_js)?;
    let felts = core::decode_felts(args).map_err(to_js)?;
    let raw = program.run_felts(&felts).map_err(to_js)?;
    Ok(core::encode_felts(&raw))
}

/// Current size of the wasm linear memory, in bytes (leak checks).
#[wasm_bindgen]
pub fn wasm_memory_bytes() -> f64 {
    ::core::arch::wasm32::memory_size(0) as f64 * 65536.0
}

fn to_js(e: core::SimError) -> JsError {
    JsError::new(&e.to_string())
}

fn parse_felt(s: &str) -> Result<cairo_vm::Felt252, JsError> {
    let s = s.trim();
    let parsed = if s.starts_with("0x") || s.starts_with("0X") {
        cairo_vm::Felt252::from_hex(s).map_err(|e| JsError::new(&format!("{e:?}")))?
    } else {
        cairo_vm::Felt252::from_dec_str(s).map_err(|e| JsError::new(&format!("{e:?}")))?
    };
    Ok(parsed)
}

/// Experimental retained VM. This is a simulation transport, not a proof API.
#[wasm_bindgen(js_name = SimContinuation)]
pub struct JsSimContinuation {
    inner: crate::continuation::SimContinuation,
}

#[wasm_bindgen(js_class = SimContinuation)]
impl JsSimContinuation {
    pub fn load(executable_json: &str, initial: &[u8]) -> Result<JsSimContinuation, JsError> {
        let state = core::decode_felts(initial).map_err(to_js)?;
        let mut inner =
            crate::continuation::SimContinuation::load(executable_json, &state).map_err(to_js)?;
        if inner.resume(2_000_000).map_err(to_js)? != crate::continuation::Progress::NeedInput {
            return Err(JsError::new(
                "invalid state or initialization exceeded its step limit",
            ));
        }
        Ok(Self { inner })
    }

    /// 0 = waiting for input; 1 = interrupted; 2 = ended.
    pub fn advance(&mut self, word: u32, quantum: usize) -> Result<u32, JsError> {
        self.inner.submit(0, word.into()).map_err(to_js)?;
        self.resume(quantum)
    }

    pub fn resume(&mut self, quantum: usize) -> Result<u32, JsError> {
        Ok(match self.inner.resume(quantum).map_err(to_js)? {
            crate::continuation::Progress::NeedInput => 0,
            crate::continuation::Progress::Interrupted => 1,
            crate::continuation::Progress::Ended => 2,
        })
    }

    pub fn request_checkpoint(&mut self, quantum: usize) -> Result<u32, JsError> {
        self.inner.submit(1, 0_u32.into()).map_err(to_js)?;
        self.resume(quantum)
    }

    pub fn restart(&mut self, initial: &[u8]) -> Result<(), JsError> {
        let state = core::decode_felts(initial).map_err(to_js)?;
        self.inner.restart(&state).map_err(to_js)?;
        if self.inner.resume(2_000_000).map_err(to_js)? != crate::continuation::Progress::NeedInput
        {
            return Err(JsError::new(
                "invalid checkpoint or initialization exceeded its step limit",
            ));
        }
        Ok(())
    }

    /// The Cairo snapshot, unchanged; no GameState is serialized here.
    pub fn snapshot(&self) -> Vec<u8> {
        core::encode_felts(&self.inner.snapshot)
    }
    pub fn checkpoint(&self) -> Vec<u8> {
        core::encode_felts(&self.inner.checkpoint)
    }
    pub fn status(&self) -> Result<u32, JsError> {
        self.inner
            .status
            .and_then(|x| u32::try_from(x).ok())
            .ok_or_else(|| JsError::new("no completed tic status"))
    }
    pub fn total_steps(&self) -> f64 {
        self.inner.total_steps() as f64
    }
    pub fn last_steps(&self) -> f64 {
        self.inner.last_steps() as f64
    }
}
