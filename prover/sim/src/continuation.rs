// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
//! Experimental simulation-only continuation. Cairo owns the game state;
//! Rust supplies one command and reads Cairo-produced snapshots/checkpoints.
//! A pause happens before hp_poll, never halfway through a hint instruction.

use std::any::Any;

use cairo_lang_casm::hints::{Hint, StarknetHint};
use cairo_lang_runner::casm_run::{cell_ref_to_relocatable, extract_relocatable, vm_get_range};
use cairo_lang_runner::CairoHintProcessor;
use cairo_vm::hint_processor::hint_processor_definition::HintProcessorLogic;
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;
use cairo_vm::types::relocatable::{MaybeRelocatable, Relocatable};
use cairo_vm::vm::runners::cairo_runner::CairoRunner;
use cairo_vm::Felt252;

use crate::core::{reset_processor, Result, SimError, SimProgram};

/// No next input is consumed while Interrupted. Call resume with more steps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    NeedInput,
    Interrupted,
    Ended,
}

/// Limits are prototype resource bounds, not changes to game/proof budgets.
pub const MAX_SESSION_STEPS: usize = 32_000_000;
pub const MAX_SESSION_COMMANDS: usize = 256;

pub struct SimContinuation {
    program: Program,
    runner: CairoRunner,
    processor: CairoHintProcessor<'static>,
    end: Relocatable,
    hints: Vec<Box<dyn Any>>,
    polls: Vec<bool>,
    pending: Option<Vec<Felt252>>,
    progress: Progress,
    poisoned: bool,
    commands: usize,
    pub status: Option<Felt252>,
    pub snapshot: Vec<Felt252>,
    pub checkpoint: Vec<Felt252>,
    last_steps: usize,
}

fn error(message: impl ToString) -> SimError {
    SimError::Run(message.to_string())
}

impl SimContinuation {
    /// Initialize a VM; initial state is checked by the Cairo harness before
    /// the first poll. Call resume to finish loading and reach NeedInput.
    pub fn load(executable_json: &str, initial: &[Felt252]) -> Result<Self> {
        let (program, mut processor) = SimProgram::load(executable_json)?.into_continuation_parts();
        let mut args = Vec::with_capacity(initial.len() + 1);
        args.push(Felt252::from(initial.len()));
        args.extend_from_slice(initial);
        reset_processor(&mut processor, &args);
        let mut runner =
            CairoRunner::new(&program, LayoutName::all_cairo, None, false, false, false)
                .map_err(error)?;
        let end = runner.initialize(true).map_err(error)?;
        let hints = runner
            .get_hint_data(
                &program.shared_program_data.reference_manager,
                &mut processor,
            )
            .map_err(error)?;
        let mut polls = vec![false; program.data_len()];
        for (pc, poll) in polls.iter_mut().enumerate() {
            if let Some(Some((start, len))) = program
                .shared_program_data
                .hints_collection
                .get_hint_range_for_pc(pc)
            {
                for hint in &hints[start..start + len.get()] {
                    if let Some(Hint::Starknet(StarknetHint::Cheatcode { selector, .. })) =
                        hint.downcast_ref::<Hint>()
                    {
                        if selector.value.to_bytes_be().1 == b"hp_poll" {
                            // Resuming all hints at one instruction is safe only when
                            // hp_poll is its sole hint. Reject other harness shapes.
                            if len.get() != 1 {
                                return Err(error("hp_poll must be the instruction's sole hint"));
                            }
                            *poll = true;
                        }
                    }
                }
            }
        }
        if !polls.iter().any(|&poll| poll) {
            return Err(error("not a continuation executable: missing hp_poll"));
        }
        Ok(Self {
            program,
            runner,
            processor,
            end,
            hints,
            polls,
            pending: None,
            progress: Progress::Interrupted,
            poisoned: false,
            commands: 0,
            status: None,
            snapshot: vec![],
            checkpoint: vec![],
            last_steps: 0,
        })
    }

    /// Recreate only VM state at a verified boundary; program/hint data stay cached.
    /// The initial record is checked again by the same Cairo from_felts.
    pub fn restart(&mut self, initial: &[Felt252]) -> Result<()> {
        // Initialization can fail after processor mutation; the old VM must
        // never resume with the reset processor in that case.
        self.poisoned = true;
        let mut args = Vec::with_capacity(initial.len() + 1);
        args.push(Felt252::from(initial.len()));
        args.extend_from_slice(initial);
        reset_processor(&mut self.processor, &args);
        let mut runner = CairoRunner::new(
            &self.program,
            LayoutName::all_cairo,
            None,
            false,
            false,
            false,
        )
        .map_err(error)?;
        self.end = runner.initialize(true).map_err(error)?;
        self.runner = runner;
        self.progress = Progress::Interrupted;
        self.pending = None;
        self.poisoned = false;
        self.commands = 0;
        self.status = None;
        self.snapshot.clear();
        self.checkpoint.clear();
        self.last_steps = 0;
        Ok(())
    }

    /// Queue one command at an input boundary. No batching or prediction.
    pub fn submit(&mut self, action: u32, word: Felt252) -> Result<()> {
        if self.poisoned || self.progress != Progress::NeedInput || self.pending.is_some() {
            return Err(error("submit requires a healthy input boundary"));
        }
        if action > 2 {
            return Err(error("unknown continuation action"));
        }
        if action == 0 && self.commands >= MAX_SESSION_COMMANDS {
            return Err(error(
                "session command limit: checkpoint and recreate the VM",
            ));
        }
        if action == 0 {
            self.commands += 1;
        }
        self.pending = Some(vec![Felt252::from(action), word]);
        self.progress = Progress::Interrupted;
        self.status = None;
        self.snapshot.clear();
        self.checkpoint.clear();
        Ok(())
    }

    /// Run at most `quantum` instructions, interruptible between instructions.
    /// Hint scopes, dict trackers, builtins and the instruction cache survive.
    pub fn resume(&mut self, quantum: usize) -> Result<Progress> {
        self.resume_with_step_limit(quantum, MAX_SESSION_STEPS)
    }

    fn resume_with_step_limit(&mut self, quantum: usize, step_limit: usize) -> Result<Progress> {
        if self.poisoned {
            return Err(error("failed continuation cannot resume"));
        }
        let start = self.runner.vm.get_current_step();
        let result = self.run_quantum(quantum, step_limit);
        self.last_steps = self.runner.vm.get_current_step() - start;
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    fn run_quantum(&mut self, quantum: usize, step_limit: usize) -> Result<Progress> {
        if quantum == 0 || self.progress == Progress::Ended {
            return Ok(self.progress);
        }
        for _ in 0..quantum {
            let pc = self.runner.vm.get_pc();
            if pc == self.end {
                self.progress = Progress::Ended;
                return Ok(self.progress);
            }
            if self.polls.get(pc.offset).copied().unwrap_or(false) && self.pending.is_none() {
                self.progress = Progress::NeedInput;
                return Ok(self.progress);
            }
            if self.runner.vm.get_current_step() >= step_limit {
                return Err(error(
                    "session step limit: discard VM and restore a checkpoint",
                ));
            }
            if let Some(Some((start, len))) = self
                .program
                .shared_program_data
                .hints_collection
                .get_hint_range_for_pc(pc.offset)
            {
                for index in start..start + len.get() {
                    let custom = self.hints[index]
                        .downcast_ref::<Hint>()
                        .and_then(|h| match h {
                            Hint::Starknet(h @ StarknetHint::Cheatcode { .. }) => Some(h.clone()),
                            _ => None,
                        });
                    if let Some(hint) = custom {
                        self.exchange(&hint)?;
                    } else {
                        self.processor
                            .execute_hint(
                                &mut self.runner.vm,
                                &mut self.runner.exec_scopes,
                                &self.hints[index],
                            )
                            .map_err(error)?;
                    }
                }
            }
            // This is cairo-vm's own instruction interpreter, unchanged.
            self.runner.vm.step_instruction().map_err(error)?;
        }
        self.progress = Progress::Interrupted;
        Ok(self.progress)
    }

    fn exchange(&mut self, hint: &StarknetHint) -> Result<()> {
        let StarknetHint::Cheatcode {
            selector,
            input_start,
            input_end,
            output_start,
            output_end,
        } = hint
        else {
            return Err(error("unsupported continuation hint"));
        };
        let selector = selector.value.to_bytes_be().1;
        let vm = &mut self.runner.vm;
        let first = extract_relocatable(vm, input_start).map_err(error)?;
        let end = extract_relocatable(vm, input_end).map_err(error)?;
        let inputs = vm_get_range(vm, first, end).map_err(error)?;
        let response = match selector.as_slice() {
            b"hp_poll" => {
                if !inputs.is_empty() {
                    return Err(error("hp_poll carries unexpected inputs"));
                }
                self.pending
                    .take()
                    .ok_or_else(|| error("hp_poll without input"))?
            }
            b"hp_status" => {
                if inputs.len() != 1 {
                    return Err(error("hp_status length"));
                }
                self.status = Some(inputs[0]);
                vec![]
            }
            b"hp_frame" => {
                self.snapshot = inputs;
                vec![]
            }
            b"hp_state" => {
                self.checkpoint = inputs;
                vec![]
            }
            _ => return Err(error("unsupported cheatcode in continuation program")),
        };
        let start = vm.add_memory_segment();
        let values: Vec<MaybeRelocatable> = response.into_iter().map(Into::into).collect();
        let end = vm.load_data(start, &values).map_err(error)?;
        vm.insert_value(cell_ref_to_relocatable(output_start, vm), start)
            .map_err(error)?;
        vm.insert_value(cell_ref_to_relocatable(output_end, vm), end)
            .map_err(error)?;
        Ok(())
    }

    pub fn last_steps(&self) -> usize {
        self.last_steps
    }
    pub fn total_steps(&self) -> usize {
        self.runner.vm.get_current_step()
    }
    pub fn progress(&self) -> Progress {
        self.progress
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cairo_vm::types::builtin_name::BuiltinName;

    // Generated by the checked-in, protocol-only Cairo counter harness.
    const COUNTER: &str = include_str!("../tests/fixtures/counter.executable.json");

    fn ready(session: &mut SimContinuation) {
        assert_eq!(session.resume(100_000).unwrap(), Progress::NeedInput);
    }

    fn counter(value: u32) -> SimContinuation {
        let mut session = SimContinuation::load(COUNTER, &[value.into()]).unwrap();
        ready(&mut session);
        session
    }

    fn checkpoint(session: &mut SimContinuation) -> Vec<Felt252> {
        session.submit(1, Felt252::ZERO).unwrap();
        ready(session);
        session.checkpoint.clone()
    }

    #[test]
    fn command_limit_preserves_checkpoint_and_restart_rearms_session() {
        let mut session = counter(7);
        for _ in 0..MAX_SESSION_COMMANDS {
            session.submit(0, Felt252::ONE).unwrap();
            ready(&mut session);
        }
        let before = session.total_steps();
        let error = session.submit(0, Felt252::ONE).unwrap_err();
        assert!(error.to_string().contains("command limit"));
        assert_eq!(session.total_steps(), before);
        let state = checkpoint(&mut session);
        assert_eq!(state, vec![Felt252::from(7 + MAX_SESSION_COMMANDS)]);
        session.restart(&state).unwrap();
        ready(&mut session);
        session.submit(0, Felt252::ONE).unwrap();
        ready(&mut session);
        assert_eq!(session.snapshot, vec![state[0] + Felt252::ONE]);
    }

    #[test]
    fn step_limit_poisons_partial_execution_and_checkpoint_restores_it() {
        let mut session = counter(9);
        let state = checkpoint(&mut session);
        session.submit(0, Felt252::ONE).unwrap();
        // Exercise the real error path with a small private test threshold;
        // production resume always supplies MAX_SESSION_STEPS.
        let limit = session.total_steps() + 1;
        let error = session.resume_with_step_limit(100_000, limit).unwrap_err();
        assert!(error.to_string().contains("step limit"));
        assert!(session.resume(100_000).is_err());
        assert!(session.submit(0, Felt252::ONE).is_err());
        session.restart(&state).unwrap();
        ready(&mut session);
        session.submit(0, Felt252::ONE).unwrap();
        ready(&mut session);
        assert_eq!(session.snapshot, vec![Felt252::from(10_u32)]);
    }

    #[test]
    fn failed_runner_initialization_cannot_reuse_the_old_vm() {
        let mut session = counter(11);
        let state = checkpoint(&mut session);
        let original = session.program.clone();
        // Test-only fault injection: initialization rejects duplicate builtins.
        session.program = Program::new(
            vec![BuiltinName::output, BuiltinName::output],
            vec![],
            Some(0),
            Default::default(),
            Default::default(),
            Default::default(),
            vec![],
            None,
        )
        .unwrap();
        assert!(session.restart(&state).is_err());
        assert!(session.resume(1).is_err());
        assert!(session.submit(0, Felt252::ONE).is_err());
        session.program = original;
        session.restart(&state).unwrap();
        ready(&mut session);
        session.submit(0, Felt252::ONE).unwrap();
        ready(&mut session);
        assert_eq!(session.snapshot, vec![Felt252::from(12_u32)]);
    }

    #[test]
    fn malformed_restart_poisons_and_clean_restart_recovers() {
        let mut session = counter(5);
        session.restart(&[]).unwrap();
        assert!(session.resume(100_000).is_err());
        assert!(session.resume(0).is_err());
        session.restart(&[Felt252::from(5_u32)]).unwrap();
        ready(&mut session);
        session.submit(2, Felt252::ZERO).unwrap();
        assert_eq!(session.resume(100_000).unwrap(), Progress::Ended);
        assert_eq!(session.resume(0).unwrap(), Progress::Ended);
        assert!(session.submit(0, Felt252::ONE).is_err());
    }
}
