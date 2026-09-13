// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Exercise subprocess admission without scheduling any circuit proof. The verifier double
//! reports the fixture's output cells; real cryptographic checks live in leaf-verify.
#![cfg(unix)]
mod common;

use axum::http::StatusCode;
use common::{run_segments, Harness, KEY};
use hellproof_wrapper::config::Backend;
use hellproof_wrapper::db::Db;
use hellproof_wrapper::felt::{leaf_output_words, output_cells_from_words, Felt};
use hellproof_wrapper::{api, AppState};
use serde_json::{json, Value};
use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

fn harness(pin: Option<&str>, segment: &Value) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = common::config(dir.path(), 8, 3600);
    cfg.backend = Backend::Subprocess;
    cfg.programs[0].program_hash = pin.map(str::to_owned);
    let preimage: Vec<Felt> = segment["output_preimage"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| Felt::parse(f.as_str().unwrap()).unwrap())
        .collect();
    let output: Vec<String> = output_cells_from_words(&leaf_output_words(&preimage))
        .iter()
        .map(|f| f.to_hex())
        .collect();
    // A deliberately different bootloader hash must not be mistaken for the task pin.
    let report = json!({"ok":true,"program_hash":"0xdead","output":output});
    let verifier = dir.path().join("verify");
    let marker = dir.path().join("verified");
    std::fs::write(
        &verifier,
        format!(
            "#!/bin/sh\ncase \"$*\" in *--expect-bootloader*) ;; *) exit 3 ;; esac\ntouch '{}'\nprintf '%s\\n' '{}'\n",
            marker.display(),
            report
        ),
    )
    .unwrap();
    std::fs::set_permissions(&verifier, std::fs::Permissions::from_mode(0o700)).unwrap();
    cfg.leaf_verify_bin = Some(verifier);
    cfg.leaf_bootloader = Some(dir.path().join("bootloader.json"));
    std::fs::write(cfg.leaf_bootloader.as_ref().unwrap(), r#"{"data":["0x1"]}"#).unwrap();
    // No scheduler: a successful admission queues work for later, never starts heavy jobs.
    let state = Arc::new(AppState::new(cfg, Db::open_memory().unwrap()));
    let router = api::router(Arc::clone(&state));
    Harness {
        state,
        router,
        _dir: dir,
    }
}

#[tokio::test]
async fn whole_run_binds_task_hash_before_enqueuing_any_job() {
    let segment = run_segments(1, 1).remove(0);
    for pin in [None, Some("0x6")] {
        let h = harness(pin, &segment);
        let (code, response) = h
            .submit(json!({"run_id":"wrong","program":"segment_stub","segments":[segment]}))
            .await;
        assert_eq!(code, StatusCode::BAD_REQUEST, "{response}");
        assert!(h.state.db.queue_depths().unwrap().is_empty());
        assert!(h.state.db.run("wrong").unwrap().is_none());
        assert!(!h._dir.path().join("verified").exists());
    }
    let h = harness(Some("5"), &segment);
    let (code, response) = h
        .submit(json!({"run_id":"right","program":"segment_stub","segments":[segment]}))
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{response}");
    assert!(h
        .state
        .db
        .segment("right", 0)
        .unwrap()
        .unwrap()
        .leaf_key
        .is_some());
    assert!(h
        .state
        .db
        .queue_depths()
        .unwrap()
        .iter()
        .all(|(kind, _, _)| kind == "verify"));
}

#[tokio::test]
async fn resumable_complete_binds_task_hash_before_batching() {
    let segment = run_segments(1, 1).remove(0);
    for pin in [None, Some("0x6"), Some("5")] {
        let h = harness(pin, &segment);
        let (code, response) = h.put_segment("resume", &segment).await;
        assert_eq!(code, StatusCode::OK, "{response}");
        assert_eq!(response["verified"], true);
        assert!(h._dir.path().join("verified").exists());
        assert!(h.state.db.queue_depths().unwrap().is_empty());
        let (code, response) = h
            .post_as(
                KEY,
                "/v1/runs/resume/complete",
                json!({"program":"segment_stub"}),
            )
            .await;
        if pin == Some("5") {
            assert_eq!(code, StatusCode::ACCEPTED, "{response}");
            assert!(h
                .state
                .db
                .segment("resume", 0)
                .unwrap()
                .unwrap()
                .leaf_key
                .is_some());
        } else {
            assert_eq!(code, StatusCode::UNPROCESSABLE_ENTITY, "{response}");
            assert_eq!(
                h.state.db.run("resume").unwrap().unwrap().status,
                hellproof_wrapper::model::RunStatus::Collecting
            );
            assert!(h
                .state
                .db
                .segment("resume", 0)
                .unwrap()
                .unwrap()
                .leaf_key
                .is_none());
            assert!(h.state.db.queue_depths().unwrap().is_empty());
            assert!(h.state.db.open_batch().unwrap().is_none());
        }
    }
}

fn d14_harness() -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = common::config(dir.path(), 8, 3600);
    cfg.programs[0].program_hash = Some("0x5".into());
    cfg.programs[0].output_layout = hellproof_wrapper::config::OutputLayout::D14;
    let state = Arc::new(AppState::new(cfg, Db::open_memory().unwrap()));
    let router = api::router(Arc::clone(&state));
    Harness {
        state,
        router,
        _dir: dir,
    }
}

fn d14_segments() -> Vec<Value> {
    let mut segments = run_segments(1, 2);
    segments[0]["output_preimage"] = json!([
        "0x5",
        "0x1",
        "0x20000000000001",
        "0x30000000000001",
        "0x0",
        "0x19",
        "0x0",
        "0x123",
        "0x0",
        "0x0",
        "0x0"
    ]);
    segments[1]["output_preimage"] = json!([
        "0x5",
        "0x1",
        "0x30000000000001",
        "0x40000000000001",
        "0x19",
        "0x32",
        "0x0",
        "0x456",
        "0x0",
        "0x0",
        "0x0"
    ]);
    segments
}

#[tokio::test]
async fn d14_chain_uses_h_in_and_h_out_on_both_routes() {
    let segments = d14_segments();
    let h = d14_harness();
    let (code, response) = h
        .submit(json!({"run_id":"whole-d14","program":"segment_stub","segments":segments}))
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{response}");
    assert_eq!(h.state.db.segments("whole-d14").unwrap().len(), 2);

    let h = d14_harness();
    for segment in &segments {
        let (code, response) = h.put_segment("resume-d14", segment).await;
        assert_eq!(code, StatusCode::OK, "{response}");
    }
    let (code, response) = h
        .post_as(
            KEY,
            "/v1/runs/resume-d14/complete",
            json!({"program":"segment_stub"}),
        )
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{response}");
    assert!(h
        .state
        .db
        .segments("resume-d14")
        .unwrap()
        .iter()
        .all(|s| s.leaf_key.is_some()));
}

#[tokio::test]
async fn d14_broken_links_and_unknown_shapes_never_queue_circuit_work() {
    for case in ["broken", "version", "short", "long", "legacy"] {
        let mut segments = d14_segments();
        match case {
            "broken" => segments[1]["output_preimage"][2] = json!("0x30000000000002"),
            "version" => segments[1]["output_preimage"][1] = json!("0x2"),
            "short" => {
                segments[1]["output_preimage"].as_array_mut().unwrap().pop();
            }
            "long" => segments[1]["output_preimage"]
                .as_array_mut()
                .unwrap()
                .push(json!("0x0")),
            "legacy" => {
                segments[1]["output_preimage"] =
                    json!(["0x5", "0x30000000000001", "0x40000000000001", "0x19", "0x0"])
            }
            _ => unreachable!(),
        }
        let expected = match case {
            "broken" => "does not continue",
            "version" => "unknown D14 output version",
            _ => "requires 11 felts",
        };
        let h = d14_harness();
        let (code, response) = h
            .submit(json!({"run_id":"bad-d14","program":"segment_stub","segments":segments}))
            .await;
        assert_eq!(code, StatusCode::BAD_REQUEST, "{case}: {response}");
        assert!(
            response.to_string().contains(expected),
            "{case}: {response}"
        );
        assert!(h.state.db.queue_depths().unwrap().is_empty());
        assert!(h.state.db.run("bad-d14").unwrap().is_none());

        let h = d14_harness();
        for segment in &segments {
            let (code, response) = h.put_segment("bad-d14", segment).await;
            assert_eq!(code, StatusCode::OK, "{case}: {response}");
        }
        let (code, response) = h
            .post_as(
                KEY,
                "/v1/runs/bad-d14/complete",
                json!({"program":"segment_stub"}),
            )
            .await;
        assert_eq!(code, StatusCode::UNPROCESSABLE_ENTITY, "{case}: {response}");
        assert!(
            response.to_string().contains(expected),
            "{case}: {response}"
        );
        assert!(h.state.db.queue_depths().unwrap().is_empty());
        assert!(h.state.db.open_batch().unwrap().is_none());
        assert!(h
            .state
            .db
            .segments("bad-d14")
            .unwrap()
            .iter()
            .all(|s| s.leaf_key.is_none()));
    }
}
