// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! The resumable per-segment upload protocol: `GET .../segments`, `PUT .../segments/{index}`,
//! `POST .../complete`, `DELETE /v1/runs/{id}`. Same `stub` backend and real scheduler as
//! `tests/service.rs`; see the README's "Resumable per-segment uploads" section for the wire
//! contract this exercises.

mod common;

use axum::http::StatusCode;
use common::{run_segments, Harness, ADMIN_KEY, KEY, OTHER_KEY};
use serde_json::json;

#[tokio::test]
async fn a_bare_put_creates_the_run_and_complete_finishes_it_like_a_whole_post() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-1";
    let segments = run_segments(1, 3);

    // No `POST /v1/runs` at all: the first `PUT` brings the run into existence.
    for seg in &segments {
        let (code, res) = h.put_segment(run_id, seg).await;
        assert_eq!(code, StatusCode::OK, "{res}");
        assert_eq!(res["verified"], true, "{res}");
        assert_eq!(res["duplicate"], false);
        assert!(res["sha256"].as_str().unwrap().len() == 64);
    }

    let (code, listed) = h.get(&format!("/v1/runs/{run_id}/segments")).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(listed["status"], "collecting");
    assert_eq!(listed["held"].as_array().unwrap().len(), 3);
    assert_eq!(listed["segments"].as_array().unwrap().len(), 3);
    assert!(listed["segments"][0]["verified"].as_bool().unwrap());

    // `solo: true` (D6): wrapped alone immediately instead of waiting on `batch_max_runs = 8`.
    let (code, done) = h
        .post_as(
            KEY,
            &format!("/v1/runs/{run_id}/complete"),
            json!({ "program": "segment_stub", "solo": true }),
        )
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{done}");
    assert_eq!(done["run_id"], run_id);
    assert_ne!(done["status"], "rejected");

    let done = h.wait_run(run_id, &["done"], 10_000).await;
    assert_eq!(done["progress"]["segments"], 3);
    assert_eq!(done["progress"]["verified"], 3);
    assert_eq!(done["progress"]["leaves_done"], 3);
}

#[tokio::test]
async fn put_is_idempotent_by_content_and_conflicts_on_a_changed_index() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-idempotent";
    let segments = run_segments(2, 1);
    let seg = &segments[0];

    let (code, first) = h.put_segment(run_id, seg).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(first["duplicate"], false);

    // Same bytes again: a no-op that reports the same verdict, not a re-verification.
    let (code, second) = h.put_segment(run_id, seg).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(second["duplicate"], true);
    assert_eq!(second["sha256"], first["sha256"]);
    assert_eq!(second["verified"], true);

    // Different bytes under the same index: refused, not silently overwritten.
    let mut changed = seg.clone();
    changed["proof"]["data"] = json!(common::base64_of("a different proof"));
    let (code, err) = h.put_segment(run_id, &changed).await;
    assert_eq!(code, StatusCode::CONFLICT, "{err}");
}

#[tokio::test]
async fn put_rejects_out_of_range_indices() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-range";
    let segments = run_segments(3, 1);

    // Beyond `max_segments_per_run` (64 by default): out of range unconditionally.
    let mut too_far = segments[0].clone();
    too_far["index"] = json!(64);
    let (code, err) = h.put_segment(run_id, &too_far).await;
    assert_eq!(code, StatusCode::BAD_REQUEST, "{err}");

    // Declare an expected count via `POST /v1/runs`, then a matching-URL index beyond it is
    // also rejected, even though it is well under `max_segments_per_run`.
    let run_id2 = "resumable-range-2";
    let (code, created) = h
        .submit(json!({ "run_id": run_id2, "program": "segment_stub", "expected_segments": 2 }))
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{created}");
    assert_eq!(created["status"], "collecting");

    let mut seg2 = segments[0].clone();
    seg2["index"] = json!(2);
    let (code, err) = h.put_segment(run_id2, &seg2).await;
    assert_eq!(code, StatusCode::BAD_REQUEST, "{err}");
    assert!(
        err["error"].as_str().unwrap().contains("out of range"),
        "{err}"
    );
}

#[tokio::test]
async fn complete_rejects_a_broken_chain_with_422() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-broken-chain";
    let mut segments = run_segments(4, 2);
    // Break the h_in/h_out chain between segment 0 and segment 1.
    segments[1]["output_preimage"][1] = json!("0xdead");

    for seg in &segments {
        let (code, res) = h.put_segment(run_id, seg).await;
        assert_eq!(code, StatusCode::OK, "{res}");
    }

    let (code, err) = h
        .post_as(
            KEY,
            &format!("/v1/runs/{run_id}/complete"),
            json!({ "program": "segment_stub" }),
        )
        .await;
    assert_eq!(code, StatusCode::UNPROCESSABLE_ENTITY, "{err}");
    assert!(
        err["error"].as_str().unwrap().contains("does not continue"),
        "{err}"
    );

    // Nothing was queued: the chain break is caught before any work is scheduled.
    let depths = h.state.db.queue_depths().unwrap();
    assert!(depths.is_empty(), "{depths:?}");
}

#[tokio::test]
async fn complete_requires_every_segment_and_rejects_gaps() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-gap";
    let segments = run_segments(5, 3);

    // Upload 0 and 2, skip 1.
    h.put_segment(run_id, &segments[0]).await;
    h.put_segment(run_id, &segments[2]).await;

    let (code, err) = h
        .post_as(
            KEY,
            &format!("/v1/runs/{run_id}/complete"),
            json!({ "program": "segment_stub" }),
        )
        .await;
    assert_eq!(code, StatusCode::UNPROCESSABLE_ENTITY, "{err}");
    assert!(err["error"].as_str().unwrap().contains("missing"), "{err}");
}

#[tokio::test]
async fn complete_checks_the_declared_segment_count() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-expected-count";
    let (code, _) = h
        .submit(json!({ "run_id": run_id, "program": "segment_stub", "expected_segments": 2 }))
        .await;
    assert_eq!(code, StatusCode::ACCEPTED);

    let segments = run_segments(6, 1);
    h.put_segment(run_id, &segments[0]).await;

    // Only 1 of the declared 2 segments is in: `/complete` must not queue a partial game.
    let (code, err) = h
        .post_as(KEY, &format!("/v1/runs/{run_id}/complete"), json!({}))
        .await;
    assert_eq!(code, StatusCode::UNPROCESSABLE_ENTITY, "{err}");
    assert!(
        err["error"].as_str().unwrap().contains("expected 2"),
        "{err}"
    );
}

/// The stub backend always verifies "ok" (it has no real verifier to run), so this cannot exercise
/// an actual failed *cryptographic* verification — that path is `pipeline_e2e`'s
/// `a_tampered_proof_is_rejected_in_seconds`, which needs the real verifier. What every backend
/// enforces is `shape_segment`'s structural cross-check, before anything is stored: a segment
/// whose `public_outputs` do not match its own `output_preimage` is refused outright, and nothing
/// bad is left behind for a corrected re-upload to conflict with.
#[tokio::test]
async fn a_structurally_inconsistent_segment_is_refused_and_leaves_nothing_behind() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-bad-shape";
    let segments = run_segments(7, 2);

    h.put_segment(run_id, &segments[0]).await;

    let mut bad = segments[1].clone();
    bad["public_outputs"] = json!(["0x1", "0x2"]);
    let (code, err) = h.put_segment(run_id, &bad).await;
    assert_eq!(code, StatusCode::BAD_REQUEST, "{err}");
    assert!(
        err["error"].as_str().unwrap().contains("do not match"),
        "{err}"
    );

    // Not persisted: the server still only holds segment 0.
    let (code, listed) = h.get(&format!("/v1/runs/{run_id}/segments")).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(listed["held"], json!([0]), "{listed}");

    // The corrected segment uploads cleanly, and the run completes.
    let (code, res) = h.put_segment(run_id, &segments[1]).await;
    assert_eq!(code, StatusCode::OK, "{res}");
    let (code, done) = h
        .post_as(
            KEY,
            &format!("/v1/runs/{run_id}/complete"),
            json!({ "program": "segment_stub", "solo": true }),
        )
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{done}");
    h.wait_run(run_id, &["done"], 10_000).await;
}

#[tokio::test]
async fn explicit_run_creation_fixes_the_program_up_front() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-explicit";
    let (code, created) = h
        .submit(json!({
            "run_id": run_id,
            "program": "segment_stub",
            "player": "0x1234",
            "expected_segments": 1,
            "solo": true,
        }))
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{created}");
    assert_eq!(created["status"], "collecting");

    // Re-posting the same run_id (still collecting) is idempotent, like the whole-run POST.
    let (code, again) = h
        .submit(json!({ "run_id": run_id, "program": "segment_stub" }))
        .await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(again["duplicate"], true);

    let segments = run_segments(8, 1);
    h.put_segment(run_id, &segments[0]).await;

    // `/complete` does not need `program` again since the run already has one; giving a
    // different one is refused.
    let (code, err) = h
        .post_as(
            KEY,
            &format!("/v1/runs/{run_id}/complete"),
            json!({ "program": "doom_run" }),
        )
        .await;
    assert_eq!(code, StatusCode::BAD_REQUEST, "{err}");

    let (code, done) = h
        .post_as(KEY, &format!("/v1/runs/{run_id}/complete"), json!({}))
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{done}");
    h.wait_run(run_id, &["done"], 10_000).await;
}

#[tokio::test]
async fn ownership_is_enforced_on_the_new_endpoints() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-owned";
    let segments = run_segments(9, 1);
    h.put_segment(run_id, &segments[0]).await; // owned by KEY's account

    // A different, non-admin account cannot touch KEY's run.
    let (code, _) = h.put_segment_as(OTHER_KEY, run_id, &segments[0]).await;
    assert_eq!(code, StatusCode::FORBIDDEN);

    let (code, _) = h
        .post_as(OTHER_KEY, &format!("/v1/runs/{run_id}/complete"), json!({}))
        .await;
    assert_eq!(code, StatusCode::FORBIDDEN);

    let (code, _) = h.delete_as(OTHER_KEY, &format!("/v1/runs/{run_id}")).await;
    assert_eq!(code, StatusCode::FORBIDDEN);

    // An admin key, by contrast, is deliberately allowed to act on anyone's run.
    let (code, res) = h
        .post_as(
            ADMIN_KEY,
            &format!("/v1/runs/{run_id}/complete"),
            json!({ "program": "segment_stub" }),
        )
        .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{res}");
}

#[tokio::test]
async fn delete_only_works_on_an_unfinished_run() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-delete";
    let segments = run_segments(10, 2);
    h.put_segment(run_id, &segments[0]).await;

    let (code, _) = h.delete_as(KEY, &format!("/v1/runs/{run_id}")).await;
    assert_eq!(code, StatusCode::NO_CONTENT);

    // Gone: a fresh PUT starts a brand new (empty) run under the same id.
    let (code, listed) = h.get(&format!("/v1/runs/{run_id}/segments")).await;
    assert_eq!(code, StatusCode::NOT_FOUND, "{listed}");

    // Deleting an unknown run is a 404, not a silent success.
    let (code, _) = h.delete_as(KEY, &format!("/v1/runs/{run_id}")).await;
    assert_eq!(code, StatusCode::NOT_FOUND);

    // Once a run is completed it can no longer be deleted.
    let run_id2 = "resumable-delete-2";
    for seg in run_segments(11, 1) {
        h.put_segment(run_id2, &seg).await;
    }
    h.post_as(
        KEY,
        &format!("/v1/runs/{run_id2}/complete"),
        json!({ "program": "segment_stub" }),
    )
    .await;
    let (code, err) = h.delete_as(KEY, &format!("/v1/runs/{run_id2}")).await;
    assert_eq!(code, StatusCode::CONFLICT, "{err}");
}

/// R8-A2 for the resumable protocol: a "restart" (a fresh `Db`/`AppState`/router built against
/// the same on-disk database) still holds the segments a client already uploaded, so a resumed
/// client can pick up where it left off instead of re-uploading everything.
#[tokio::test]
async fn an_upload_survives_a_restart_and_can_be_resumed() {
    let dir = tempfile::tempdir().unwrap();
    let segments = run_segments(12, 2);

    {
        let (_, router) = common::build(dir.path(), 8, 3600);
        let (code, res) = common::call(
            &router,
            axum::http::Request::builder()
                .method("PUT")
                .uri("/v1/runs/resumed/segments/0")
                .header("authorization", format!("Bearer {KEY}"))
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::to_vec(&segments[0]).unwrap(),
                ))
                .unwrap(),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{res}");
        // The router (and its scheduler task) is dropped here: this stands in for the process
        // exiting between the two segment uploads.
    }

    // Rebuild against the same directory: same database file, fresh in-memory state.
    let (state, router) = common::build(dir.path(), 8, 3600);

    let (code, listed) = common::call(
        &router,
        axum::http::Request::builder()
            .uri("/v1/runs/resumed/segments")
            .header("authorization", format!("Bearer {KEY}"))
            .body(axum::body::Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{listed}");
    assert_eq!(
        listed["held"],
        json!([0]),
        "the first segment survived the restart"
    );
    assert_eq!(listed["segments"][0]["verified"], true);

    // Finish the upload and complete the run against the rebuilt service.
    let (code, res) = common::call(
        &router,
        axum::http::Request::builder()
            .method("PUT")
            .uri("/v1/runs/resumed/segments/1")
            .header("authorization", format!("Bearer {KEY}"))
            .header("content-type", "application/json")
            .body(axum::body::Body::from(
                serde_json::to_vec(&segments[1]).unwrap(),
            ))
            .unwrap(),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{res}");

    let (code, done) = common::call(
        &router,
        axum::http::Request::builder()
            .method("POST")
            .uri("/v1/runs/resumed/complete")
            .header("authorization", format!("Bearer {KEY}"))
            .header("content-type", "application/json")
            .body(axum::body::Body::from(
                serde_json::to_vec(&json!({ "program": "segment_stub", "solo": true })).unwrap(),
            ))
            .unwrap(),
    )
    .await;
    assert_eq!(code, StatusCode::ACCEPTED, "{done}");

    // Poll status through the same rebuilt router.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let (_, v) = common::call(
            &router,
            axum::http::Request::builder()
                .uri("/v1/runs/resumed")
                .header("authorization", format!("Bearer {KEY}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
        if v["status"] == "done" {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "timed out: {v}");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let _ = state;
}

/// Raw-bincode `PUT`, driven by headers instead of a JSON envelope: what a non-browser client
/// (or a browser client optimizing away the base64 step) can do instead.
#[tokio::test]
async fn put_accepts_a_raw_bincode_body_via_headers() {
    let h = Harness::start(8, 3600);
    let run_id = "resumable-raw";
    let proof_bytes = b"a raw proof, not base64 at all".to_vec();

    let req = axum::http::Request::builder()
        .method("PUT")
        .uri(format!("/v1/runs/{run_id}/segments/0"))
        .header("authorization", format!("Bearer {KEY}"))
        .header("content-type", "application/octet-stream")
        .header("x-hellproof-output-preimage", "0x5,0x1,0x2,0xfa,0x0")
        .header("x-hellproof-args", "0x1,0xfa")
        .body(axum::body::Body::from(proof_bytes.clone()))
        .unwrap();
    let (code, res) = h.call(req).await;
    assert_eq!(code, StatusCode::OK, "{res}");
    assert_eq!(res["verified"], true);
    assert_eq!(res["size_bytes"], proof_bytes.len());

    let (code, listed) = h.get(&format!("/v1/runs/{run_id}/segments")).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(listed["held"], json!([0]));
}

#[tokio::test]
async fn get_segments_on_an_unknown_run_is_404() {
    let h = Harness::start(8, 3600);
    let (code, _) = h.get("/v1/runs/never-existed/segments").await;
    assert_eq!(code, StatusCode::NOT_FOUND);
}
