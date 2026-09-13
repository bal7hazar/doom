// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Target-independent core of the simulation runner.
//!
//! The whole point of this module is the split between what is parsed **once**
//! (at [`SimProgram::load`] time) and what has to be rebuilt for **every** tic.
//! See `docs/spikes/S3.md` for the measured cost of each part.
//!
//! Cached in [`SimProgram`] (one-off, ~tens of ms):
//!  * the `.executable.json` deserialization (`Executable`),
//!  * the assembled [`Program`] (bytecode as `MaybeRelocatable`, hints
//!    collection). Cloning it is `O(1)`: cairo-vm keeps the heavy
//!    `SharedProgramData` behind an `Arc`,
//!  * the `string_to_hint` map (hint-string -> `Hint`), which is otherwise
//!    rebuilt from the executable on every call,
//!  * a [`CairoHintProcessor`] instance, reset (not rebuilt) between calls,
//!  * the entrypoint choice and the run configuration.
//!
//! Rebuilt for every independent call (the stateless API below):
//!  * the [`CairoRunner`] and the `VirtualMachine` it owns (memory segments,
//!    builtin runners, execution scopes). cairo-vm exposes no "reset" API, and
//!    the memory of a finished run is not resettable; an unfinished run can
//!    instead be retained by the experimental `continuation` module,
//!  * the user arguments (`Vec<Arg>`), which hold the serialized input felts.

use std::cell::RefCell;

use cairo_lang_casm::hints::Hint;
use cairo_lang_executable::executable::{EntryPointKind, Executable, ExecutableEntryPoint};
use cairo_lang_runner::{build_hints_dict, Arg, CairoHintProcessor};
use cairo_lang_utils::unordered_hash_map::UnorderedHashMap;
use cairo_vm::types::builtin_name::BuiltinName;
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;
use cairo_vm::types::relocatable::{MaybeRelocatable, Relocatable};
use cairo_vm::vm::runners::builtin_runner::BuiltinRunner;
use cairo_vm::vm::runners::cairo_runner::CairoRunner;
use cairo_vm::Felt252;

/// Size of the fixed-width little-endian encoding of a felt, in bytes.
pub const FELT_BYTES: usize = 32;

#[derive(Debug, thiserror::Error)]
pub enum SimError {
    #[error("failed to parse the executable JSON: {0}")]
    Parse(String),
    #[error("no `{0:?}` entrypoint in the executable")]
    NoEntrypoint(EntryPointKind),
    #[error("failed to build the cairo-vm program: {0}")]
    Program(String),
    #[error("cairo run failed: {0}")]
    Run(String),
    #[error("the executable does not use the output builtin")]
    NoOutputBuiltin,
    #[error("could not read the output segment: {0}")]
    Output(String),
    #[error("argument buffer length {0} is not a multiple of 32 bytes")]
    BadArgsLength(usize),
    #[error("felt at index {0} is not a valid field element")]
    BadFelt(usize),
    #[error("the Cairo entrypoint panicked: {0:?}")]
    CairoPanic(Vec<Felt252>),
    #[error("cairo run failed ({reason}); panic payload: {payload:?}")]
    RunPanic {
        reason: String,
        payload: Vec<Felt252>,
    },
}

pub type Result<T> = std::result::Result<T, SimError>;

/// How the cached program is executed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum RunMode {
    /// Non-proof run of the `Bootloader` entrypoint: the entry code is called
    /// like a plain function, the VM stops on its `ret`. Cheapest; this is the
    /// mode the real-time simulation uses.
    #[default]
    Execution,
    /// Proof-mode initialization of the `Standalone` entrypoint (the exact
    /// setup the prover uses), but with trace collection, memory relocation,
    /// hole filling and segment finalization switched off. Kept to check that
    /// the real-time path and the provable path agree, and to measure the
    /// overhead of the proof-mode wrapper.
    ProofShapeNoTrace,
}

/// Per-call timing breakdown, in milliseconds.
#[derive(Clone, Copy, Debug, Default)]
pub struct Timings {
    /// Decoding the little-endian argument bytes into felts.
    pub decode_args: f64,
    /// Building the `CairoRunner` + `VirtualMachine` and initializing them.
    pub init: f64,
    /// Running the VM until the final pc (the actual Cairo steps).
    pub run: f64,
    /// Reading the output segment back as felts.
    pub read_output: f64,
    /// Encoding the output felts into little-endian bytes.
    pub encode_output: f64,
    /// Number of Cairo steps executed by the last run.
    pub steps: f64,
}

impl Timings {
    pub fn total(&self) -> f64 {
        self.decode_args + self.init + self.run + self.read_output + self.encode_output
    }

    pub fn as_array(&self) -> [f64; 6] {
        [
            self.decode_args,
            self.init,
            self.run,
            self.read_output,
            self.encode_output,
            self.steps,
        ]
    }
}

/// A Scarb `#[executable]` parsed once and runnable many times.
pub struct SimProgram {
    program: Program,
    /// Kept so that [`SimProgram::fresh_hint_processor`] can rebuild a hint
    /// processor from scratch (used by the bench to price processor reuse).
    string_to_hint: UnorderedHashMap<String, Hint>,
    processor: RefCell<CairoHintProcessor<'static>>,
    mode: RunMode,
    layout: LayoutName,
    builtins: Vec<BuiltinName>,
    timings: RefCell<Timings>,
    /// Scratch buffer reused across calls for the decoded arguments.
    args_scratch: RefCell<Vec<Felt252>>,
    /// Scratch buffer reused across calls for the raw output felts.
    out_scratch: RefCell<Vec<Felt252>>,
}

impl SimProgram {
    /// Parse a Scarb `.executable.json` once.
    pub fn load(executable_json: &str) -> Result<Self> {
        let executable: Executable =
            serde_json::from_str(executable_json).map_err(|e| SimError::Parse(e.to_string()))?;
        Self::from_executable(&executable, RunMode::default())
    }

    pub fn load_with_mode(executable_json: &str, mode: RunMode) -> Result<Self> {
        let executable: Executable =
            serde_json::from_str(executable_json).map_err(|e| SimError::Parse(e.to_string()))?;
        Self::from_executable(&executable, mode)
    }

    pub fn from_executable(executable: &Executable, mode: RunMode) -> Result<Self> {
        let wanted = match mode {
            RunMode::Execution => EntryPointKind::Bootloader,
            RunMode::ProofShapeNoTrace => EntryPointKind::Standalone,
        };
        let entrypoint: &ExecutableEntryPoint = executable
            .entrypoints
            .iter()
            .find(|e| e.kind == wanted)
            .ok_or_else(|| SimError::NoEntrypoint(wanted.clone()))?;

        let data: Vec<MaybeRelocatable> = executable
            .program
            .bytecode
            .iter()
            .map(Felt252::from)
            .map(MaybeRelocatable::from)
            .collect();
        let (hints, string_to_hint) = build_hints_dict(&executable.program.hints);

        let program = match mode {
            RunMode::ProofShapeNoTrace => Program::new_for_proof(
                entrypoint.builtins.clone(),
                data,
                entrypoint.offset,
                entrypoint.offset + 4,
                hints,
                Default::default(),
                Default::default(),
                vec![],
                None,
            ),
            RunMode::Execution => Program::new(
                entrypoint.builtins.clone(),
                data,
                Some(entrypoint.offset),
                hints,
                Default::default(),
                Default::default(),
                vec![],
                None,
            ),
        }
        .map_err(|e| SimError::Program(e.to_string()))?;

        Ok(Self {
            program,
            string_to_hint: string_to_hint.clone(),
            processor: RefCell::new(make_processor(string_to_hint)),
            mode,
            layout: LayoutName::all_cairo,
            builtins: entrypoint.builtins.clone(),
            timings: RefCell::new(Timings::default()),
            args_scratch: RefCell::new(Vec::new()),
            out_scratch: RefCell::new(Vec::new()),
        })
    }

    pub(crate) fn into_continuation_parts(self) -> (Program, CairoHintProcessor<'static>) {
        (self.program, self.processor.into_inner())
    }

    pub fn mode(&self) -> RunMode {
        self.mode
    }

    pub fn builtins(&self) -> &[BuiltinName] {
        &self.builtins
    }

    pub fn timings(&self) -> Timings {
        *self.timings.borrow()
    }

    /// Build a brand new hint processor, as `stwo-cairo`'s `execute` does on
    /// every call. Only used to price the alternative.
    pub fn fresh_hint_processor(&self) -> CairoHintProcessor<'static> {
        make_processor(self.string_to_hint.clone())
    }

    /// Run the entrypoint on `args` (already Cairo-serialized felts) and return
    /// the serialized outputs.
    pub fn run_felts(&self, args: &[Felt252]) -> Result<Vec<Felt252>> {
        let mut processor = self.processor.borrow_mut();
        reset_processor(&mut processor, args);
        let mut timings = Timings::default();
        let out = self.run_with(&mut processor, &mut timings)?;
        let mut slot = self.timings.borrow_mut();
        slot.init = timings.init;
        slot.run = timings.run;
        slot.read_output = timings.read_output;
        slot.steps = timings.steps;
        Ok(out)
    }

    /// Same as [`SimProgram::run_felts`] but with a caller-provided hint
    /// processor, so the bench can compare a reused processor with a freshly
    /// built one.
    pub fn run_felts_with(
        &self,
        processor: &mut CairoHintProcessor<'static>,
        args: &[Felt252],
    ) -> Result<Vec<Felt252>> {
        reset_processor(processor, args);
        let mut timings = Timings::default();
        let out = self.run_with(processor, &mut timings)?;
        *self.timings.borrow_mut() = timings;
        Ok(out)
    }

    fn run_with(
        &self,
        processor: &mut CairoHintProcessor<'static>,
        timings: &mut Timings,
    ) -> Result<Vec<Felt252>> {
        let t0 = crate::clock::now_ms();
        // A `CairoRunner` owns the `VirtualMachine`, its memory segments and
        // its builtin runners; none of that survives a run, so one runner per
        // independent call is needed here. `continuation` retains an unfinished
        // execution instead. The `Program` clone next to it is O(1).
        let proof_mode = self.mode == RunMode::ProofShapeNoTrace;
        let mut runner = CairoRunner::new(
            &self.program,
            self.layout,
            None,
            proof_mode,
            /* trace_enabled */ false,
            /* disable_trace_padding */ proof_mode,
        )
        .map_err(|e| SimError::Run(e.to_string()))?;
        let end = runner
            .initialize(/* allow_missing_builtins */ true)
            .map_err(|e| SimError::Run(e.to_string()))?;
        let t1 = crate::clock::now_ms();

        if let Err(e) = runner.run_until_pc(end, processor) {
            return Err(run_error(e.to_string(), processor));
        }
        // No trace, no hole filling, no memory relocation and no segment
        // finalization: none of it is needed to obtain the outputs.
        if let Err(e) = runner.end_run(
            /* disable_trace_padding */ true, /* disable_finalize_all */ false,
            processor, /* fill_holes */ false,
        ) {
            return Err(run_error(e.to_string(), processor));
        }
        let t2 = crate::clock::now_ms();

        let out = self.read_output(&runner)?;
        let t3 = crate::clock::now_ms();

        timings.init = t1 - t0;
        timings.run = t2 - t1;
        timings.read_output = t3 - t2;
        timings.steps = runner.vm.get_current_step() as f64;
        Ok(out)
    }

    fn read_output(&self, runner: &CairoRunner) -> Result<Vec<Felt252>> {
        let output = runner
            .vm
            .get_builtin_runners()
            .iter()
            .find_map(|b| match b {
                BuiltinRunner::Output(o) => Some(o),
                _ => None,
            })
            .ok_or(SimError::NoOutputBuiltin)?;
        let base = output.base();
        let size = output
            .get_used_cells(&runner.vm.segments)
            .map_err(|e| SimError::Output(e.to_string()))?;
        let mut out = self.out_scratch.borrow_mut();
        out.clear();
        out.reserve(size);
        for offset in 0..size {
            let addr = Relocatable::from((base as isize, offset));
            let felt = runner
                .vm
                .get_integer(addr)
                .map_err(|e| SimError::Output(e.to_string()))?;
            out.push(*felt);
        }
        Ok(out.clone())
    }

    /// Run from a little-endian byte buffer (32 bytes per felt) and return the
    /// outputs in the same encoding. This is the shape the browser uses.
    pub fn run_bytes(&self, args: &[u8]) -> Result<Vec<u8>> {
        let t0 = crate::clock::now_ms();
        let felts = {
            let mut scratch = self.args_scratch.borrow_mut();
            decode_felts_into(args, &mut scratch)?;
            scratch.clone()
        };
        let t1 = crate::clock::now_ms();

        let out = self.run_felts(&felts)?;

        let t2 = crate::clock::now_ms();
        let bytes = encode_felts(&out);
        let t3 = crate::clock::now_ms();

        let mut timings = self.timings.borrow_mut();
        timings.decode_args = t1 - t0;
        timings.encode_output = t3 - t2;
        Ok(bytes)
    }
}

/// A failed run is usually a Cairo panic: the entry code's
/// `assert 0 = panic_indicator` fails right after an `AddMarker` hint stored
/// the panic payload in the processor's markers.
fn run_error(reason: String, processor: &CairoHintProcessor<'static>) -> SimError {
    match processor.markers.last() {
        Some(payload) => SimError::RunPanic {
            reason,
            payload: payload.clone(),
        },
        None => SimError::Run(reason),
    }
}

fn make_processor(string_to_hint: UnorderedHashMap<String, Hint>) -> CairoHintProcessor<'static> {
    CairoHintProcessor {
        runner: None,
        user_args: vec![vec![Arg::Array(vec![])]],
        string_to_hint,
        starknet_state: Default::default(),
        run_resources: Default::default(),
        syscalls_used_resources: Default::default(),
        no_temporary_segments: false,
        markers: Default::default(),
        panic_traceback: Default::default(),
    }
}

/// Put a hint processor back into its pre-run state and install new arguments.
///
/// Everything the VM run can touch is cleared here; the expensive
/// `string_to_hint` map is left untouched, which is the whole point.
pub(crate) fn reset_processor(processor: &mut CairoHintProcessor<'static>, args: &[Felt252]) {
    processor.user_args = vec![vec![Arg::Array(
        args.iter().map(|f| Arg::Value(*f)).collect(),
    )]];
    processor.starknet_state = Default::default();
    processor.run_resources = Default::default();
    processor.syscalls_used_resources = Default::default();
    processor.markers.clear();
    processor.panic_traceback.clear();
}

/// Decode a little-endian felt buffer (32 bytes per felt) into `out`.
pub fn decode_felts_into(bytes: &[u8], out: &mut Vec<Felt252>) -> Result<()> {
    if bytes.len() % FELT_BYTES != 0 {
        return Err(SimError::BadArgsLength(bytes.len()));
    }
    let n = bytes.len() / FELT_BYTES;
    out.clear();
    out.reserve(n);
    for (i, chunk) in bytes.chunks_exact(FELT_BYTES).enumerate() {
        let mut buf = [0u8; FELT_BYTES];
        buf.copy_from_slice(chunk);
        let felt = Felt252::from_bytes_le(&buf);
        // `from_bytes_le` reduces modulo p; reject values that were not already
        // canonical so that a JS bug cannot silently change the simulation.
        if felt.to_bytes_le() != buf {
            return Err(SimError::BadFelt(i));
        }
        out.push(felt);
    }
    Ok(())
}

pub fn decode_felts(bytes: &[u8]) -> Result<Vec<Felt252>> {
    let mut out = Vec::new();
    decode_felts_into(bytes, &mut out)?;
    Ok(out)
}

/// Encode felts as fixed 32-byte little-endian values.
pub fn encode_felts(felts: &[Felt252]) -> Vec<u8> {
    let mut bytes = vec![0u8; felts.len() * FELT_BYTES];
    for (i, felt) in felts.iter().enumerate() {
        bytes[i * FELT_BYTES..(i + 1) * FELT_BYTES].copy_from_slice(&felt.to_bytes_le());
    }
    bytes
}

/// Body of a `-> Array<felt252>` return value.
///
/// The entry code hands the output builtin segment to the Cairo function as
/// the array it appends to, so the output segment *is* the Cairo
/// serialization of the return value: `[len, e0, .., e_{len-1}]` for an
/// `Array<felt252>`. A Cairo panic never reaches this point: the entry code
/// ends with `assert 0 = panic_indicator`, which turns a panic into a VM error
/// ([`SimError::Run`], with the panic payload attached when available).
pub fn array_body(raw: &[Felt252]) -> Result<&[Felt252]> {
    let (len, body) = raw
        .split_first()
        .ok_or_else(|| SimError::Output("empty output segment".to_owned()))?;
    if *len != Felt252::from(body.len() as u64) {
        return Err(SimError::Output(format!(
            "output segment says {len:#x} felts but carries {}",
            body.len()
        )));
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn felts(values: &[u64]) -> Vec<Felt252> {
        values.iter().copied().map(Felt252::from).collect()
    }

    #[test]
    fn encode_decode_round_trip() {
        let original = felts(&[0, 1, 42, u64::MAX]);
        let bytes = encode_felts(&original);
        assert_eq!(bytes.len(), original.len() * FELT_BYTES);
        assert_eq!(decode_felts(&bytes).unwrap(), original);
    }

    #[test]
    fn felts_are_little_endian() {
        let bytes = encode_felts(&felts(&[0x0102]));
        assert_eq!(bytes[0], 0x02);
        assert_eq!(bytes[1], 0x01);
        assert!(bytes[2..].iter().all(|b| *b == 0));
    }

    #[test]
    fn empty_buffer_decodes_to_nothing() {
        assert!(decode_felts(&[]).unwrap().is_empty());
    }

    #[test]
    fn a_truncated_buffer_is_rejected() {
        let err = decode_felts(&[0u8; FELT_BYTES + 1]).unwrap_err();
        assert!(matches!(err, SimError::BadArgsLength(33)), "{err}");
    }

    #[test]
    fn a_non_canonical_felt_is_rejected() {
        // 2^256 - 1 is larger than the STARK prime, so it would silently wrap.
        let err = decode_felts(&[0xffu8; FELT_BYTES]).unwrap_err();
        assert!(matches!(err, SimError::BadFelt(0)), "{err}");
    }

    #[test]
    fn array_body_strips_the_length_prefix() {
        let raw = felts(&[3, 10, 20, 30]);
        assert_eq!(array_body(&raw).unwrap(), &felts(&[10, 20, 30])[..]);
    }

    #[test]
    fn array_body_rejects_a_wrong_length() {
        let raw = felts(&[7, 10, 20, 30]);
        assert!(matches!(array_body(&raw), Err(SimError::Output(_))));
        assert!(matches!(array_body(&[]), Err(SimError::Output(_))));
    }
}
