// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! End-to-end behaviour of the service on the `stub` pipeline backend: submission, verification,
//! batching (D6), fold, and the persistence/resume guarantee (R8-A2).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{run_body, Harness, ADMIN_KEY, KEY};
use hellproof_wrapper::db::Db;
use hellproof_wrapper::model::{JobKind, JobState};
use serde_json::json;

#[tokio::test]
async fn a_batch_of_two_runs_folds_into_one_root() {
    let h = Harness::start(2, 600);

    let (code, a) = h.submit(run_body(1, 2, false)).await;
    assert_eq!(code, StatusCode::ACCEPTED, "{a}");
    let (code, b) = h.submit(run_body(2, 3, false)).await;
    assert_eq!(code, StatusCode::ACCEPTED, "{b}");

    let run_a = a["run_id"].as_str().unwrap().to_string();
    let run_b = b["run_id"].as_str().unwrap().to_string();
    let done = h.wait_run(&run_a, &["done"], 10_000).await;
    h.wait_run(&run_b, &["done"], 10_000).await;

    // Every stage is reported.
    assert_eq!(done["progress"]["segments"], 2);
    assert_eq!(done["progress"]["verified"], 2);
    assert_eq!(done["progress"]["leaves_done"], 2);
    assert!(done["timings"]["total_ms"].is_number());

    let batch_id = done["batch_id"].as_str().unwrap().to_string();
    let (code, batch) = h
        .get(&format!("/v1/batches/{batch_id}?include=proof"))
        .await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(batch["status"], "done");
    assert_eq!(batch["runs"].as_array().unwrap().len(), 2);

    // Fold order: run A's segments then run B's, each in index order — this is the list the
    // on-chain consumer needs to map leaves back to players.
    let leaves = batch["leaves"].as_array().unwrap();
    assert_eq!(leaves.len(), 5);
    assert_eq!(leaves[0]["run_id"], run_a.as_str());
    assert_eq!(leaves[1]["segment_index"], 1);
    assert_eq!(leaves[2]["run_id"], run_b.as_str());
    assert_eq!(leaves[4]["segment_index"], 2);
    for (i, leaf) in leaves.iter().enumerate() {
        assert_eq!(leaf["position"], i as u64);
    }
    assert!(batch["root_proof_felts"].is_array());
    assert!(batch["packed_output"].is_object());
}

#[tokio::test]
async fn a_solo_run_is_wrapped_without_waiting_for_the_batch() {
    // M = 8 and T = 10 min: a shared batch would not close during this test.
    let h = Harness::start(8, 600);
    let (_, other) = h.submit(run_body(1, 1, false)).await;
    let (_, solo) = h.submit(run_body(2, 1, true)).await;

    let solo_id = solo["run_id"].as_str().unwrap().to_string();
    let done = h.wait_run(&solo_id, &["done"], 10_000).await;
    let (_, batch) = h
        .get(&format!(
            "/v1/batches/{}",
            done["batch_id"].as_str().unwrap()
        ))
        .await;
    assert_eq!(
        batch["runs"].as_array().unwrap().len(),
        1,
        "a solo batch holds one run"
    );

    // The shared batch is still open with the other run in it.
    let other_id = other["run_id"].as_str().unwrap().to_string();
    let other = h.wait_run(&other_id, &["queued"], 5_000).await;
    assert_ne!(other["batch_id"], done["batch_id"]);
}

#[tokio::test]
async fn an_admin_can_close_the_open_batch_early() {
    let h = Harness::start(8, 3600);
    let (_, a) = h.submit(run_body(1, 1, false)).await;
    let run_id = a["run_id"].as_str().unwrap().to_string();
    h.wait_run(&run_id, &["queued"], 5_000).await;

    let (code, closed) = h.close_batches().await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(closed["closed"].as_array().unwrap().len(), 1);
    h.wait_run(&run_id, &["done"], 10_000).await;
}

#[tokio::test]
async fn the_deadline_closes_a_batch_that_never_fills_up() {
    // T = 0 s: the batch closes on the first scheduler tick after the run is verified.
    let h = Harness::start(8, 0);
    let (_, a) = h.submit(run_body(1, 1, false)).await;
    let run_id = a["run_id"].as_str().unwrap().to_string();
    h.wait_run(&run_id, &["done"], 10_000).await;
}

fn metric_counter(metrics: &str, series: &str) -> u64 {
    let prefix = format!("{series} ");
    metrics
        .lines()
        .find_map(|line| line.strip_prefix(&prefix))
        .map(|value| value.parse().expect("counter value must be an integer"))
        .unwrap_or(0)
}

#[tokio::test]
async fn identical_leaves_are_proven_once() {
    assert_identical_leaf_reuse(false).await;
}

#[tokio::test]
async fn finished_leaves_are_cached_before_the_second_submission() {
    assert_identical_leaf_reuse(true).await;
}

async fn assert_identical_leaf_reuse(warm_second_submission: bool) {
    let h = Harness::start(2, 600);
    // Two runs with the same seed submit the same (program, args) segments.
    let (_, a) = h.submit(run_body(7, 2, warm_second_submission)).await;
    if warm_second_submission {
        // A completed solo run is a state barrier, independent of scheduler timing.
        h.wait_run(a["run_id"].as_str().unwrap(), &["done"], 10_000)
            .await;
        assert_eq!(
            metric_counter(&h.state.metrics.render(), "wrapper_leaf_cache_hits_total"),
            0
        );
    }
    let mut body = run_body(7, 2, warm_second_submission);
    body["run_id"] = json!("second-run");
    let (_, b) = h.submit(body).await;

    let a = h
        .wait_run(a["run_id"].as_str().unwrap(), &["done"], 10_000)
        .await;
    let b = h
        .wait_run(b["run_id"].as_str().unwrap(), &["done"], 10_000)
        .await;

    // The two runs share both leaf keys: 4 segments, 2 leaf proofs.
    let keys = |v: &serde_json::Value| -> Vec<String> {
        v["segments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["leaf_key"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(keys(&a), keys(&b));
    let metrics = h.state.metrics.render();
    assert_eq!(
        metric_counter(
            &metrics,
            "wrapper_jobs_total{kind=\"leaf\",outcome=\"done\"}"
        ),
        2,
        "{metrics}"
    );
    assert_eq!(
        metric_counter(
            &metrics,
            "wrapper_jobs_total{kind=\"verify\",outcome=\"done\"}"
        ),
        4,
        "{metrics}"
    );
    let hits_before_third = metric_counter(&metrics, "wrapper_leaf_cache_hits_total");
    if warm_second_submission {
        assert_eq!(
            hits_before_third, 2,
            "the second run must reuse both finished leaves"
        );
    }

    // A later run reuses the finished proofs outright (the content-hash cache).
    let mut third = run_body(7, 2, true);
    third["run_id"] = json!("third-run");
    let (_, c) = h.submit(third).await;
    let c = h
        .wait_run(c["run_id"].as_str().unwrap(), &["done"], 10_000)
        .await;
    assert_eq!(keys(&a), keys(&c));
    let metrics = h.state.metrics.render();
    // The concurrently submitted second run may already have reused finished leaves.
    // Once both runs are done, the third must add exactly two hits to that snapshot.
    assert_eq!(
        metric_counter(&metrics, "wrapper_leaf_cache_hits_total"),
        hits_before_third + 2,
        "{metrics}"
    );
    assert_eq!(
        metric_counter(
            &metrics,
            "wrapper_jobs_total{kind=\"leaf\",outcome=\"done\"}"
        ),
        2,
        "{metrics}"
    );
    assert_eq!(
        metric_counter(
            &metrics,
            "wrapper_jobs_total{kind=\"verify\",outcome=\"done\"}"
        ),
        6,
        "{metrics}"
    );
}

#[tokio::test]
async fn the_same_submission_twice_is_one_run() {
    let h = Harness::start(8, 3600);
    let mut body = run_body(3, 1, false);
    body["run_id"] = json!("stable-id");
    let (code, first) = h.submit(body.clone()).await;
    assert_eq!(code, StatusCode::ACCEPTED);
    let (code, second) = h.submit(body.clone()).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(second["duplicate"], true);
    assert_eq!(first["run_id"], second["run_id"]);

    // Same id, different content: refused rather than silently overwritten.
    let mut changed = run_body(4, 1, false);
    changed["run_id"] = json!("stable-id");
    let (code, _) = h.submit(changed).await;
    assert_eq!(code, StatusCode::CONFLICT);
}

#[tokio::test]
async fn authentication_and_authorisation_are_enforced() {
    let h = Harness::start(8, 3600);
    let req = Request::builder()
        .method("POST")
        .uri("/v1/runs")
        .body(Body::from("{}"))
        .unwrap();
    assert_eq!(h.call(req).await.0, StatusCode::UNAUTHORIZED);

    let (code, _) = h.submit_as("wrong", run_body(1, 1, false)).await;
    assert_eq!(code, StatusCode::UNAUTHORIZED);

    // Closing a batch needs an admin key.
    let req = Request::builder()
        .method("POST")
        .uri("/v1/batches/close")
        .header("authorization", format!("Bearer {KEY}"))
        .body(Body::empty())
        .unwrap();
    assert_eq!(h.call(req).await.0, StatusCode::FORBIDDEN);
    assert_ne!(ADMIN_KEY, KEY);
}

#[tokio::test]
async fn invalid_submissions_are_rejected_before_any_work() {
    let h = Harness::start(8, 3600);

    // Broken h_in/h_out chain.
    let mut body = run_body(1, 2, false);
    body["segments"][1]["output_preimage"][1] = json!("0xdead");
    let (code, err) = h.submit(body).await;
    assert_eq!(code, StatusCode::BAD_REQUEST);
    assert!(
        err["error"].as_str().unwrap().contains("does not continue"),
        "{err}"
    );

    // Unknown program.
    let mut body = run_body(1, 1, false);
    body["program"] = json!("doom_run");
    assert_eq!(h.submit(body).await.0, StatusCode::BAD_REQUEST);

    // No segments: this now creates a `collecting` run for the resumable upload protocol
    // (see `resumable_uploads.rs`), not an error.
    let body = json!({"program": "segment_stub", "segments": []});
    let (code, res) = h.submit(body).await;
    assert_eq!(code, StatusCode::ACCEPTED);
    assert_eq!(res["status"], "collecting");

    // But an unknown program is still rejected immediately, even with no segments.
    let body = json!({"program": "doom_run", "segments": []});
    assert_eq!(h.submit(body).await.0, StatusCode::BAD_REQUEST);

    // Nothing was queued.
    let depths = h.state.db.queue_depths().unwrap();
    assert!(depths.is_empty(), "{depths:?}");
}

#[tokio::test]
async fn metrics_and_health_are_exposed() {
    let h = Harness::start(2, 600);
    let (_, a) = h.submit(run_body(1, 1, true)).await;
    h.wait_run(a["run_id"].as_str().unwrap(), &["done"], 10_000)
        .await;

    // The scheduler persists `done` before exporting its queue/run gauges. Poll the
    // public endpoint until that eventual update is observable, with a bounded deadline.
    let expected_metrics = [
        "wrapper_jobs_total{kind=\"verify\",outcome=\"done\"}",
        "wrapper_jobs_total{kind=\"leaf\",outcome=\"done\"}",
        "wrapper_jobs_total{kind=\"fold\",outcome=\"done\"}",
        "wrapper_job_duration_seconds_count{kind=\"fold\"}",
        "wrapper_queue_depth{kind=\"leaf\",state=\"done\"}",
        "wrapper_runs{status=\"done\"}",
    ];
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let req = Request::builder()
            .uri("/metrics")
            .body(Body::empty())
            .unwrap();
        let res = h.router.clone().oneshot_text(req).await;
        let missing: Vec<_> = expected_metrics
            .iter()
            .filter(|expected| !res.contains(**expected))
            .collect();
        if missing.is_empty() {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "metrics did not converge: missing {missing:?} in:\n{res}"
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }

    let req = Request::builder()
        .uri("/healthz")
        .body(Body::empty())
        .unwrap();
    let (code, health) = h.call(req).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(health["batch_policy"]["max_runs"], 2);
}

/// R8-A2: the queue survives a restart. A job that was `running` when the process died is
/// re-queued, not lost and not silently left running.
#[test]
fn the_queue_resumes_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("queue.sqlite3");

    {
        let db = Db::open(&path).unwrap();
        db.insert_run("run1", "0xabc", None, "segment_stub", false, "hash", 2)
            .unwrap();
        db.insert_segment(
            "run1",
            0,
            "leafA",
            "[]",
            "[]",
            "[]",
            Some("/tmp/p0"),
            "bincode_b64",
        )
        .unwrap();
        db.insert_segment(
            "run1",
            1,
            "leafB",
            "[]",
            "[]",
            "[]",
            Some("/tmp/p1"),
            "bincode_b64",
        )
        .unwrap();
        db.enqueue(JobKind::Verify, "run1:0", Some("run1"), Some(0), None)
            .unwrap();
        db.enqueue(JobKind::Verify, "run1:1", Some("run1"), Some(1), None)
            .unwrap();
        db.ensure_leaf("leafA").unwrap();
        db.set_leaf_status("leafA", "running", None, None, None, None)
            .unwrap();

        let claimed = db.claim(&[JobKind::Verify], 2).unwrap();
        assert_eq!(claimed.len(), 2);
        db.finish_job(claimed[0].id, JobState::Done, None).unwrap();
        // claimed[1] stays `running`: this is the process dying mid-job.
    }

    let db = Db::open(&path).unwrap();
    assert_eq!(db.recover().unwrap(), 1, "one running job was re-queued");
    assert_eq!(db.leaf("leafA").unwrap().unwrap().status, "queued");

    // The re-queued job is claimable again, and its attempt count carried over.
    let again = db.claim(&[JobKind::Verify], 5).unwrap();
    assert_eq!(again.len(), 1);
    assert_eq!(again[0].seg_index, Some(1));
    assert_eq!(again[0].attempts, 2);

    // The finished job is not replayed.
    db.finish_job(again[0].id, JobState::Done, None).unwrap();
    assert!(db.claim(&[JobKind::Verify], 5).unwrap().is_empty());
    assert!(db.run("run1").unwrap().is_some(), "the run itself survived");
}

/// A restart in the middle of a fold leaves the batch closed and the fold re-queued.
#[test]
fn a_fold_interrupted_by_a_restart_is_retried() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("queue.sqlite3");
    {
        let db = Db::open(&path).unwrap();
        db.insert_run("run1", "0xabc", None, "segment_stub", false, "hash", 1)
            .unwrap();
        db.insert_segment("run1", 0, "leafA", "[]", "[]", "[]", None, "bincode_b64")
            .unwrap();
        db.create_batch("batch1", false, None).unwrap();
        db.assign_run_to_batch("run1", "batch1").unwrap();
        db.close_batch("batch1").unwrap();
        db.enqueue(JobKind::Fold, "batch1", None, None, Some("batch1"))
            .unwrap();
        let claimed = db.claim(&[JobKind::Fold], 1).unwrap();
        assert_eq!(claimed.len(), 1);
        db.set_batch_status(
            "batch1",
            hellproof_wrapper::model::BatchStatus::Folding,
            None,
        )
        .unwrap();
    }
    let db = Db::open(&path).unwrap();
    db.recover().unwrap();
    let batch = db.batch("batch1").unwrap().unwrap();
    assert_eq!(batch.status.as_str(), "closed");
    assert_eq!(db.claim(&[JobKind::Fold], 1).unwrap().len(), 1);
    // The frozen fold order is still there.
    assert_eq!(db.batch_leaves("batch1").unwrap().len(), 1);
}

/// Small helper: read a text body.
#[allow(async_fn_in_trait)]
trait OneshotText {
    async fn oneshot_text(self, req: Request<Body>) -> String;
}

impl OneshotText for axum::Router {
    async fn oneshot_text(self, req: Request<Body>) -> String {
        use http_body_util::BodyExt;
        use tower::ServiceExt;
        let res = self.oneshot(req).await.unwrap();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        String::from_utf8_lossy(&bytes).into_owned()
    }
}
