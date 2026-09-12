// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Load-test stub (R8-A2: "20 concurrent jobs").
//!
//! On the `stub` backend this runs in a fraction of a second and checks the *scheduling* side of
//! the service under concurrency: nothing is lost, nothing is proven twice, every run reaches a
//! terminal state and the batches partition the runs exactly.
//!
//! To load-test the **real** pipeline, point the same shape of test at a configured wrapper:
//!
//! ```text
//! WRAPPER_LOAD_URL=http://127.0.0.1:8787 WRAPPER_LOAD_KEY=... WRAPPER_LOAD_RUNS=20 \
//!   cargo test --test load -- --ignored real_pipeline_load
//! ```
//!
//! Expect ~22 s per distinct leaf and ~30 s per reduction with `MAX_CIRCUIT_PROOFS = 1` (S4), so
//! 20 runs of 4 segments is ≈ 45 min of machine time: run it on a dedicated 64 GB host.

mod common;

use std::collections::BTreeSet;

use axum::http::StatusCode;
use common::{Harness, run_body};

const RUNS: usize = 20;
const SEGMENTS: u32 = 3;

#[tokio::test]
async fn twenty_concurrent_runs_all_complete() {
    let h = Harness::start(4, 600);

    let started = std::time::Instant::now();
    let mut ids = Vec::with_capacity(RUNS);
    for seed in 0..RUNS as u64 {
        // Distinct seeds => distinct leaves, so nothing is shortcut by the cache.
        let (code, body) = h.submit(run_body(seed * 1000 + 1, SEGMENTS, false)).await;
        assert_eq!(code, StatusCode::ACCEPTED, "{body}");
        ids.push(body["run_id"].as_str().unwrap().to_string());
    }
    let submit_ms = started.elapsed().as_secs_f64() * 1e3;

    // 20 runs at M = 4 fill five batches exactly; none of them needs the deadline.
    let mut batches = BTreeSet::new();
    for id in &ids {
        let run = h.wait_run(id, &["done"], 30_000).await;
        assert_eq!(run["progress"]["leaves_done"], SEGMENTS);
        batches.insert(run["batch_id"].as_str().unwrap().to_string());
    }
    let total_ms = started.elapsed().as_secs_f64() * 1e3;
    assert_eq!(batches.len(), RUNS / 4);

    // Every leaf was proven exactly once and every batch folded exactly once.
    let metrics = h.state.metrics.render();
    let leaf_done = metric(&metrics, "wrapper_jobs_total{kind=\"leaf\",outcome=\"done\"}");
    let fold_done = metric(&metrics, "wrapper_jobs_total{kind=\"fold\",outcome=\"done\"}");
    let verify_done = metric(&metrics, "wrapper_jobs_total{kind=\"verify\",outcome=\"done\"}");
    assert_eq!(leaf_done, (RUNS as u32 * SEGMENTS) as f64);
    assert_eq!(verify_done, (RUNS as u32 * SEGMENTS) as f64);
    assert_eq!(fold_done, (RUNS / 4) as f64);
    assert!(!metrics.contains("outcome=\"failed\""), "{metrics}");

    // Each batch holds its runs' leaves, in submission order, with no gaps.
    for batch in &batches {
        let (_, b) = h.get(&format!("/v1/batches/{batch}")).await;
        let leaves = b["leaves"].as_array().unwrap();
        assert_eq!(leaves.len(), 4 * SEGMENTS as usize);
        for (i, leaf) in leaves.iter().enumerate() {
            assert_eq!(leaf["position"], i as u64);
        }
    }

    eprintln!(
        "load stub: {RUNS} runs x {SEGMENTS} segments, {} batches, submit {submit_ms:.0} ms, \
         total {total_ms:.0} ms (stub backend: no proving)",
        batches.len()
    );
}

fn metric(text: &str, key: &str) -> f64 {
    text.lines()
        .find(|l| l.starts_with(key))
        .and_then(|l| l.rsplit(' ').next())
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| panic!("metric {key} not found in:\n{text}"))
}

/// The same shape against a real wrapper. Ignored by default: it needs a configured server and
/// hours of prover time.
#[tokio::test]
#[ignore = "needs WRAPPER_LOAD_URL and a running wrapper with the real pipeline"]
async fn real_pipeline_load() {
    let url = std::env::var("WRAPPER_LOAD_URL").expect("WRAPPER_LOAD_URL");
    let key = std::env::var("WRAPPER_LOAD_KEY").unwrap_or_default();
    let runs: usize = std::env::var("WRAPPER_LOAD_RUNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20);
    eprintln!(
        "Submit {runs} runs to {url} with key `{}…`. This stub does not ship an HTTP client on \
         purpose (the TypeScript client in client-ts/ is the supported one); drive it with \
         `client-ts/examples/load.ts` or curl.",
        &key.chars().take(4).collect::<String>()
    );
}
