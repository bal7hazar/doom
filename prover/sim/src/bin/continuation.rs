// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
//! Bounded native equivalence bench. Uses real immutable fixtures and checks
//! every state/snapshot felt, including partial VM runs and checkpoint reloads.
use cairo_vm::Felt252;
use hellproof_sim::{
    continuation::{Progress, SimContinuation},
    SimProgram,
};
use serde::Deserialize;
use serde_json::json;
use std::{env, fs, time::Instant};

#[derive(Deserialize)]
struct Fixture {
    name: String,
    state: Vec<String>,
    commands: Vec<u32>,
}
fn parse(s: &str) -> Felt252 {
    Felt252::from_hex(s).unwrap()
}
fn ready(session: &mut SimContinuation, quantum: usize) {
    for _ in 0..50_000 {
        match session.resume(quantum).unwrap() {
            Progress::NeedInput => return,
            Progress::Interrupted => (),
            Progress::Ended => panic!("Cairo session ended before an input boundary"),
        }
    }
    panic!("bounded continuation did not reach input boundary")
}
fn main() {
    let args: Vec<String> = env::args().collect();
    assert_eq!(
        args.len(),
        4,
        "continuation SESSION_JSON STATELESS_JSON FIXTURES_JSON"
    );
    let executable = fs::read_to_string(&args[1]).unwrap();
    let reference = SimProgram::load(&fs::read_to_string(&args[2]).unwrap()).unwrap();
    let fixtures: Vec<Fixture> =
        serde_json::from_str(&fs::read_to_string(&args[3]).unwrap()).unwrap();
    let mut rows = vec![];
    for f in fixtures {
        let mut state: Vec<Felt252> = f.state.iter().map(|s| parse(s)).collect();
        let mut session = SimContinuation::load(&executable, &state).unwrap();
        ready(&mut session, 1_000_000);
        assert_eq!(session.last_steps(), session.total_steps());
        let paused = session.total_steps();
        assert_eq!(session.resume(0).unwrap(), Progress::NeedInput);
        assert_eq!(session.total_steps(), paused);
        assert!(session.submit(3, Felt252::ZERO).is_err());
        let mut samples = vec![];
        let mut final_output = vec![];
        for (i, word) in f.commands.iter().enumerate() {
            let mut args = vec![Felt252::from(state.len())];
            args.extend_from_slice(&state);
            args.extend([Felt252::ONE, Felt252::from(*word)]);
            let expected = reference.run_felts(&args).unwrap();
            let n = usize::try_from(expected[1]).unwrap();
            let snap_n = usize::try_from(expected[n + 2]).unwrap();
            assert_eq!(expected.len(), n + 3 + snap_n);
            let started = Instant::now();
            let before = session.total_steps();
            session.submit(0, Felt252::from(*word)).unwrap();
            if i % 7 == 0 {
                assert_eq!(session.resume(101).unwrap(), Progress::Interrupted);
                assert!(
                    session.submit(0, Felt252::ZERO).is_err(),
                    "no second input while running"
                );
                ready(&mut session, 4096);
            } else {
                ready(&mut session, 1_000_000);
            }
            let ms = started.elapsed().as_secs_f64() * 1000.;
            let steps = session.total_steps() - before;
            assert_eq!(
                session.status,
                Some(expected[0]),
                "{} status at {}",
                f.name,
                i
            );
            assert_eq!(
                session.snapshot,
                expected[n + 3..],
                "{} snapshot at {}",
                f.name,
                i
            );
            let checkpoint_started = Instant::now();
            session.submit(1, Felt252::ZERO).unwrap();
            ready(&mut session, 1_000_000);
            assert_eq!(
                session.checkpoint,
                expected[2..n + 2],
                "{} state at {}",
                f.name,
                i
            );
            let checkpoint_ms = checkpoint_started.elapsed().as_secs_f64() * 1000.;
            state = session.checkpoint.clone();
            let paused = session.total_steps();
            assert_eq!(session.resume(100).unwrap(), Progress::NeedInput);
            assert_eq!(
                session.total_steps(),
                paused,
                "waiting consumes no instructions"
            );
            let mut restart_ms = 0.;
            if (i + 1) % 32 == 0 {
                let t = Instant::now();
                session.restart(&state).unwrap();
                ready(&mut session, 1_000_000);
                restart_ms = t.elapsed().as_secs_f64() * 1000.;
            }
            samples.push(json!({"tic":i,"steps":steps,"ms":ms,"checkpointMs":checkpoint_ms,"restartMs":restart_ms, "expectedStatus":u32::try_from(expected[0]).unwrap(),
                "expectedSnapshot": expected[n + 3..].iter().map(|x| u64::try_from(*x).unwrap()).collect::<Vec<_>>(),
                "expectedCheckpoint": if (i + 1) % 32 == 0 || expected[0] != Felt252::ZERO { Some(state.iter().map(|x|format!("{x:#x}")).collect::<Vec<_>>()) } else { None }}));
            final_output = expected;
            if final_output[0] != Felt252::ZERO {
                break;
            }
        }
        eprintln!(
            "{}: {} exact tics, interruptions and restarts passed",
            f.name,
            samples.len()
        );
        rows.push(json!({"name":f.name,"samples":samples,"exact":true,"finalOutput":final_output.iter().map(|x|format!("{x:#x}")).collect::<Vec<_>>()}));
    }
    // Malformed state must return before the first interactive poll.
    let mut invalid = SimContinuation::load(&executable, &[]).unwrap();
    assert_eq!(invalid.resume(1_000_000).unwrap(), Progress::Ended);
    assert!(invalid.submit(0, Felt252::ZERO).is_err());
    println!(
        "{}",
        serde_json::to_string(&json!({"cases":rows,"malformedRejected":true})).unwrap()
    );
}
