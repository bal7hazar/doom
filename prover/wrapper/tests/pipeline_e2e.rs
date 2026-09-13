// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! The real pipeline, end to end, on N browser-equivalent segment proofs.
//!
//! Ignored by default: it runs `leaf-prover` and `stwo_run_and_prove_recursive_tree` for real —
//! 32.5 GB of RSS per circuit proof and about a minute per leaf plus a minute per fold (S4).
//!
//! ```text
//! # 1. produce N browser-equivalent segment proofs (bincode extended CairoProof)
//! prover/wrapper/scripts/e2e_fixtures.sh "$SCRATCH/wrapper-e2e" 2
//!
//! # 2. run the wrapper over them
//! WRAPPER_E2E_FIXTURES=$SCRATCH/wrapper-e2e \
//! WRAPPER_E2E_BIN_DIR=$SCRATCH/proving-s4/target/release \
//! WRAPPER_E2E_PROVING=$SCRATCH/proving-s4 \
//! WRAPPER_E2E_LEAF_VERIFY=$SCRATCH/wrapper-target/release/hellproof-leaf-verify \
//! WRAPPER_E2E_LOCK=$SCRATCH/.proof-lock \
//!   cargo test --test pipeline_e2e -- --ignored --nocapture
//! ```
//!
//! `folds_the_submitted_proofs_without_reproving_them` covers the default
//! `leaf_mode = "from_proof"` (D19) and needs `WRAPPER_E2E_BIN_DIR` to hold a `leaf-prover`
//! built with `patches/proving-0001-leaf-prover-from-proof.patch`; it is skipped, loudly, when
//! that binary has no `--cairo_proof`. `wraps_two_real_segment_proofs_into_one_root` covers
//! `"rerun"` and runs against a stock upstream build.

use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use hellproof_wrapper::config::{ApiKey, Backend, Config, LeafMode, ProgramEntry};
use hellproof_wrapper::db::Db;
use hellproof_wrapper::scheduler::Scheduler;
use hellproof_wrapper::{api, AppState};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

const KEY: &str = "e2e";

struct Env {
    fixtures: PathBuf,
    repo: PathBuf,
    bin_dir: PathBuf,
    proving: PathBuf,
    leaf_verify: PathBuf,
    lock: Option<PathBuf>,
}

fn env() -> Option<Env> {
    let fixtures = PathBuf::from(std::env::var("WRAPPER_E2E_FIXTURES").ok()?);
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .ok()?;
    Some(Env {
        fixtures,
        bin_dir: PathBuf::from(std::env::var("WRAPPER_E2E_BIN_DIR").ok()?),
        proving: PathBuf::from(std::env::var("WRAPPER_E2E_PROVING").ok()?),
        leaf_verify: PathBuf::from(std::env::var("WRAPPER_E2E_LEAF_VERIFY").ok()?),
        lock: std::env::var("WRAPPER_E2E_LOCK").ok().map(PathBuf::from),
        repo,
    })
}

#[allow(clippy::field_reassign_with_default)]
fn config(e: &Env, data_dir: PathBuf, leaf_mode: LeafMode) -> Config {
    let mut cfg = Config::default();
    cfg.data_dir = data_dir;
    cfg.backend = Backend::Subprocess;
    cfg.leaf_mode = leaf_mode;
    cfg.registry.path = Some(e.repo.join("spikes/s4/registry/doom/registry.json"));
    cfg.leaf_prover_bin = Some(e.bin_dir.join("leaf-prover"));
    cfg.tree_bin = Some(e.bin_dir.join("stwo_run_and_prove_recursive_tree"));
    cfg.leaf_verify_bin = Some(e.leaf_verify.clone());
    cfg.leaf_bootloader = Some(e.proving.join(
        "crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json",
    ));
    cfg.leaf_params_json = Some(e.repo.join("prover/wasm/harness/params/leaf.json"));
    cfg.proof_lock_dir = e.lock.clone();
    cfg.max_circuit_proofs = Some(1);
    cfg.scheduler_tick_ms = 200;
    cfg.programs.push(ProgramEntry {
        id: "segment_stub".into(),
        executable: e
            .repo
            .join("spikes/s4/programs/segment_stub/target/dev/segment_stub.executable.json"),
        program_hash: None,
        hash_function: Default::default(),
    });
    cfg.api_keys.push(ApiKey {
        key: KEY.into(),
        account: "0xe2e".into(),
        admin: true,
        daily_run_quota: 0,
    });
    cfg
}

/// Turns the fixture manifest into a submission body. `with_args` mirrors what a client sends:
/// `rerun` needs the segment arguments, `from_proof` does not (D19).
fn submission(fixtures: &std::path::Path, solo: bool, with_args: bool) -> Value {
    use base64::Engine;
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(fixtures.join("manifest.json")).unwrap()).unwrap();
    let segments: Vec<Value> = manifest["segments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            let proof = std::fs::read(s["proof_path"].as_str().unwrap()).unwrap();
            let mut seg = json!({
                "index": s["index"],
                "output_preimage": s["output_preimage"],
                "proof": {
                    "format": "bincode_b64",
                    "data": base64::engine::general_purpose::STANDARD.encode(&proof),
                }
            });
            if with_args {
                seg["args"] = s["args"].clone();
            }
            seg
        })
        .collect();
    json!({ "program": "segment_stub", "solo": solo, "segments": segments })
}

/// Whether `leaf-prover` carries `patches/proving-0001-leaf-prover-from-proof.patch`.
fn leaf_prover_can_fold_a_proof(bin: &std::path::Path) -> bool {
    std::process::Command::new(bin)
        .arg("--help")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("--cairo_proof"))
        .unwrap_or(false)
}

async fn call(router: &axum::Router, req: Request<Body>) -> (StatusCode, Value) {
    let res = router.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn post(router: &axum::Router, uri: &str, body: Value) -> (StatusCode, Value) {
    let req = Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {KEY}"))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap();
    call(router, req).await
}

async fn get(router: &axum::Router, uri: &str) -> (StatusCode, Value) {
    let req = Request::builder()
        .uri(uri)
        .header("authorization", format!("Bearer {KEY}"))
        .body(Body::empty())
        .unwrap();
    call(router, req).await
}

/// `leaf_mode = "rerun"`: the server replays and re-proves every segment (the pre-D19 behaviour,
/// and what a stock upstream `leaf-prover` supports).
#[tokio::test(flavor = "multi_thread")]
#[ignore = "runs the real prover: 32.5 GB per circuit proof, minutes per run"]
async fn wraps_two_real_segment_proofs_into_one_root() {
    let e = env().expect("set WRAPPER_E2E_* (see the module docs)");
    wrap_a_run(&e, LeafMode::Rerun).await;
}

/// `leaf_mode = "from_proof"` (the default, D19): the browser's proof goes straight into the leaf
/// circuit. The segment is never run and never proven again, so the submission carries no `args`
/// at all — and the root must still be the recomposition of the submitted preimages.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "runs the real prover: 32.5 GB per circuit proof, minutes per run"]
async fn folds_the_submitted_proofs_without_reproving_them() {
    let e = env().expect("set WRAPPER_E2E_* (see the module docs)");
    let leaf_prover = e.bin_dir.join("leaf-prover");
    assert!(
        leaf_prover_can_fold_a_proof(&leaf_prover),
        "{} has no --cairo_proof: apply prover/wrapper/patches (scripts/apply_patches.sh) and \
         rebuild it",
        leaf_prover.display()
    );
    wrap_a_run(&e, LeafMode::FromProof).await;
}

async fn wrap_a_run(e: &Env, leaf_mode: LeafMode) {
    let dir = tempfile::tempdir().unwrap();
    let cfg = config(e, dir.path().to_path_buf(), leaf_mode);
    cfg.check_runnable()
        .expect("pipeline binaries and fixtures must exist");

    let db = Db::open(&dir.path().join("queue.sqlite3")).unwrap();
    let state = Arc::new(AppState::new(cfg, db));
    tokio::spawn(Scheduler::new(Arc::clone(&state)).run());
    let router = api::router(Arc::clone(&state));

    // `from_proof` needs no arguments; leaving them out is the point of the mode.
    let body = submission(&e.fixtures, true, leaf_mode == LeafMode::Rerun);
    let n = body["segments"].as_array().unwrap().len();
    let started = std::time::Instant::now();

    // `wait_verify_ms`: R8-A1 wants a verdict on the submitted proofs within seconds.
    let (code, res) = post(&router, "/v1/runs?wait_verify_ms=15000", body).await;
    let verify_wall = started.elapsed();
    assert_eq!(code, StatusCode::ACCEPTED, "{res}");
    assert_ne!(res["status"], "rejected", "{res}");
    eprintln!(
        "verification of {n} segments: {:.2} s",
        verify_wall.as_secs_f64()
    );
    assert!(
        verify_wall.as_secs() < 30,
        "verification should take seconds"
    );

    let run_id = res["run_id"].as_str().unwrap().to_string();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1800);
    let run = loop {
        let (_, run) = get(&router, &format!("/v1/runs/{run_id}")).await;
        match run["status"].as_str().unwrap_or("") {
            "done" => break run,
            "rejected" | "failed" => panic!("run did not complete: {run}"),
            _ => {}
        }
        assert!(std::time::Instant::now() < deadline, "timed out: {run}");
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    };
    let total = started.elapsed();

    // Per-stage numbers, for the record.
    eprintln!("leaf_mode = {:?}", leaf_mode);
    for seg in run["segments"].as_array().unwrap() {
        eprintln!(
            "leaf {}: {:.1} s, peak RSS {:.1} GB, verify {:.0} ms",
            seg["index"],
            seg["leaf_ms"].as_f64().unwrap_or(0.0) / 1e3,
            seg["leaf_max_rss_bytes"].as_f64().unwrap_or(0.0) / 1e9,
            seg["verify_ms"].as_f64().unwrap_or(0.0),
        );
    }

    let batch_id = run["batch_id"].as_str().unwrap();
    let (_, batch) = get(&router, &format!("/v1/batches/{batch_id}?include=packed")).await;
    eprintln!(
        "fold: {:.1} s, peak RSS {:.1} GB; root proof {} felts; end to end {:.1} s",
        batch["fold_ms"].as_f64().unwrap_or(0.0) / 1e3,
        batch["fold_max_rss_bytes"].as_f64().unwrap_or(0.0) / 1e9,
        batch["root_proof_felt_count"],
        total.as_secs_f64()
    );

    assert_eq!(batch["status"], "done");
    assert_eq!(batch["leaves"].as_array().unwrap().len(), n);
    // S4 measured 93 797 felts for N = 2 with this registry.
    let felts = batch["root_proof_felt_count"].as_u64().unwrap();
    assert!(
        (90_000..100_000).contains(&felts),
        "unexpected root proof size: {felts}"
    );

    // The root's output words are the recomposition of the leaves' preimages — the same
    // computation the on-chain consumer performs (`recursion_outputs::fold_tree`).
    let packed = batch["packed_output"].clone();
    let (preimages, leaf_hash, mv_hash) =
        hellproof_wrapper::recompose::parse_packed_output(&packed).unwrap();
    assert_eq!(preimages.len(), n);
    let root =
        hellproof_wrapper::recompose::root_from_preimages(&preimages, leaf_hash, mv_hash).unwrap();
    let program_output: Vec<u32> = serde_json::from_value(batch["program_output"].clone()).unwrap();
    assert_eq!(program_output, root.output, "root output vs recomposition");
    eprintln!(
        "leaf circuit hash {leaf_hash:08x?}\nmultiverifier hash {mv_hash:08x?}\n\
         VerificationOutput.output_hash {:?}",
        hellproof_wrapper::recompose::verification_output_hash(&root)
    );

    // The root proof felts are on disk, ready for `scarb execute -p stwo_circuit_verifier
    // --arguments-file` (see scripts/e2e_verify_root.sh).
    let (_, batch_full) = get(&router, &format!("/v1/batches/{batch_id}?include=proof")).await;
    let root_path = dir.path().join("root.proof");
    std::fs::write(
        &root_path,
        serde_json::to_vec(&batch_full["root_proof_felts"]).unwrap(),
    )
    .unwrap();
    if let Ok(keep) = std::env::var("WRAPPER_E2E_KEEP_ROOT") {
        std::fs::copy(&root_path, &keep).unwrap();
        eprintln!("root proof copied to {keep}");
    }
}

/// R8-A1: a tampered proof is rejected in seconds, before any leaf is scheduled.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the fixtures and the real verifier"]
async fn a_tampered_proof_is_rejected_in_seconds() {
    let e = env().expect("set WRAPPER_E2E_* (see the module docs)");
    let dir = tempfile::tempdir().unwrap();
    let cfg = config(&e, dir.path().to_path_buf(), LeafMode::FromProof);
    let db = Db::open(&dir.path().join("queue.sqlite3")).unwrap();
    let state = Arc::new(AppState::new(cfg, db));
    tokio::spawn(Scheduler::new(Arc::clone(&state)).run());
    let router = api::router(Arc::clone(&state));

    // Flip bytes in the middle of the first segment's proof.
    let mut body = submission(&e.fixtures, true, false);
    {
        use base64::Engine;
        let data = body["segments"][0]["proof"]["data"].as_str().unwrap();
        let mut bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .unwrap();
        let mid = bytes.len() / 2;
        for b in &mut bytes[mid..mid + 64] {
            *b ^= 0xff;
        }
        body["segments"][0]["proof"]["data"] =
            json!(base64::engine::general_purpose::STANDARD.encode(&bytes));
    }

    let started = std::time::Instant::now();
    let (code, res) = post(&router, "/v1/runs?wait_verify_ms=20000", body).await;
    let elapsed = started.elapsed();
    eprintln!("rejection in {:.2} s: {res}", elapsed.as_secs_f64());
    assert_eq!(code, StatusCode::UNPROCESSABLE_ENTITY, "{res}");
    assert_eq!(res["status"], "rejected");
    assert!(
        elapsed.as_secs() < 20,
        "R8-A1: reject an invalid leaf in seconds"
    );

    // No leaf was ever queued.
    let depths = state.db.queue_depths().unwrap();
    assert!(
        depths.iter().all(|(kind, _, _)| kind == "verify"),
        "expensive work was scheduled for a rejected run: {depths:?}"
    );
}

/// The resumable per-segment upload protocol (README "Resumable per-segment uploads"), against
/// the same two real `segment_stub` proofs `wraps_two_real_segment_proofs_into_one_root` submits
/// as one `POST`: `PUT` each segment on its own — no `POST /v1/runs` at all — then
/// `POST .../complete`, and check it folds into the same shape of root proof.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "runs the real prover: 32.5 GB per circuit proof, minutes per run"]
async fn resumable_upload_wraps_two_real_segment_proofs_into_one_root() {
    use base64::Engine;

    let e = env().expect("set WRAPPER_E2E_* (see the module docs)");
    let dir = tempfile::tempdir().unwrap();
    let cfg = config(&e, dir.path().to_path_buf(), LeafMode::FromProof);
    cfg.check_runnable()
        .expect("pipeline binaries and fixtures must exist");

    let db = Db::open(&dir.path().join("queue.sqlite3")).unwrap();
    let state = Arc::new(AppState::new(cfg, db));
    tokio::spawn(Scheduler::new(Arc::clone(&state)).run());
    let router = api::router(Arc::clone(&state));

    let manifest: Value =
        serde_json::from_slice(&std::fs::read(e.fixtures.join("manifest.json")).unwrap()).unwrap();
    let segments = manifest["segments"].as_array().unwrap();
    let run_id = "resumable-e2e";

    // No `args` at all: `from_proof` folds the submitted proof, exactly like the whole-run test.
    for s in segments {
        let proof = std::fs::read(s["proof_path"].as_str().unwrap()).unwrap();
        let index = s["index"].as_u64().unwrap();
        let body = json!({
            "index": index,
            "output_preimage": s["output_preimage"],
            "proof": {
                "format": "bincode_b64",
                "data": base64::engine::general_purpose::STANDARD.encode(&proof),
            },
        });
        let req = Request::builder()
            .method("PUT")
            .uri(format!("/v1/runs/{run_id}/segments/{index}"))
            .header("authorization", format!("Bearer {KEY}"))
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_vec(&body).unwrap()))
            .unwrap();
        let started = std::time::Instant::now();
        let (code, res) = call(&router, req).await;
        eprintln!(
            "segment {index} verified in {:.2} s: {res}",
            started.elapsed().as_secs_f64()
        );
        assert_eq!(code, StatusCode::OK, "{res}");
        assert_eq!(res["verified"], true, "{res}");
    }

    let (code, listed) = get(&router, &format!("/v1/runs/{run_id}/segments")).await;
    assert_eq!(code, StatusCode::OK, "{listed}");
    assert_eq!(listed["held"].as_array().unwrap().len(), segments.len());

    let (code, res) = post(
        &router,
        &format!("/v1/runs/{run_id}/complete"),
        json!({ "program": "segment_stub", "solo": true }),
    )
    .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{res}");
    assert_ne!(res["status"], "rejected", "{res}");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1800);
    let run = loop {
        let (_, run) = get(&router, &format!("/v1/runs/{run_id}")).await;
        match run["status"].as_str().unwrap_or("") {
            "done" => break run,
            "rejected" | "failed" => panic!("run did not complete: {run}"),
            _ => {}
        }
        assert!(std::time::Instant::now() < deadline, "timed out: {run}");
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    };

    let batch_id = run["batch_id"].as_str().unwrap();
    let (_, batch) = get(&router, &format!("/v1/batches/{batch_id}")).await;
    assert_eq!(batch["status"], "done");
    assert_eq!(batch["leaves"].as_array().unwrap().len(), segments.len());
    eprintln!(
        "resumable upload: root proof {} felts, same fixtures as the whole-run test",
        batch["root_proof_felt_count"]
    );
}
