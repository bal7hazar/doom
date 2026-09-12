// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! HTTP surface. See `README.md` for the JSON schema; `client-ts/` mirrors these types.

use std::collections::BTreeMap;

use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use crate::auth::Identity;
use crate::db::now_ms;
use crate::model::*;
use crate::{Shared, validate};

#[derive(Debug, Serialize)]
pub struct ApiError {
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

pub struct Failure(StatusCode, ApiError);

impl IntoResponse for Failure {
    fn into_response(self) -> Response {
        (self.0, axum::Json(self.1)).into_response()
    }
}

fn fail(code: StatusCode, msg: impl Into<String>) -> Failure {
    Failure(code, ApiError { error: msg.into(), detail: None })
}

type ApiResult<T> = Result<T, Failure>;

pub fn router(state: Shared) -> Router {
    let body_limit = state.cfg.max_body_bytes;
    Router::new()
        .route("/healthz", get(healthz))
        .route("/metrics", get(metrics))
        .route("/v1/runs", post(submit_run))
        .route("/v1/runs/{id}", get(run_status))
        .route("/v1/batches/{id}", get(batch_status))
        .route("/v1/batches/close", post(close_batches))
        // A game's worth of segment proofs is megabytes (3 MB each at 2^20 steps), well over
        // axum's 2 MB default: replace it with our own configured limit.
        .layer(axum::extract::DefaultBodyLimit::disable())
        .layer(tower_http::limit::RequestBodyLimitLayer::new(body_limit))
        .with_state(state)
}

fn identify(state: &Shared, headers: &HeaderMap) -> ApiResult<Identity> {
    let header = headers.get(axum::http::header::AUTHORIZATION).and_then(|v| v.to_str().ok());
    state
        .auth
        .authenticate(header)
        .map_err(|e| fail(StatusCode::UNAUTHORIZED, e.message()))
}

async fn healthz(State(state): State<Shared>) -> impl IntoResponse {
    axum::Json(serde_json::json!({
        "ok": true,
        "uptime_ms": now_ms() - state.started_at_ms,
        "backend": state.cfg.backend,
        "registry_sha256": state.registry_hash,
        "batch_policy": { "max_runs": state.policy.max_runs, "max_wait_ms": state.policy.max_wait_ms },
        "max_circuit_proofs": state.cfg.effective_max_circuit_proofs(),
    }))
}

async fn metrics(State(state): State<Shared>) -> impl IntoResponse {
    (
        [(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        state.metrics.render(),
    )
}

#[derive(Debug, Deserialize, Default)]
pub struct SubmitQuery {
    /// Block up to this long waiting for the verification verdict, so a client can see an
    /// invalid proof rejected synchronously (R8-A1 asks for "< 5 s"). 0 = return immediately.
    #[serde(default)]
    pub wait_verify_ms: u64,
}

async fn submit_run(
    State(state): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<SubmitQuery>,
    body: axum::body::Bytes,
) -> ApiResult<Response> {
    let id = identify(&state, &headers)?;
    let sub: RunSubmission = serde_json::from_slice(&body)
        .map_err(|e| fail(StatusCode::BAD_REQUEST, format!("invalid JSON body: {e}")))?;

    if id.daily_run_quota > 0 {
        let used = state
            .db
            .runs_submitted_since(&id.account, now_ms() - 24 * 3600 * 1000)
            .map_err(internal)?;
        if used >= id.daily_run_quota {
            return Err(fail(
                StatusCode::TOO_MANY_REQUESTS,
                format!("daily quota of {} runs reached", id.daily_run_quota),
            ));
        }
    }

    let valid = validate::validate(&sub, &state.cfg, &state.registry_hash)
        .map_err(|e| fail(StatusCode::BAD_REQUEST, format!("{e:#}")))?;

    // Idempotency: the same run id with the same content is the same run.
    if let Some((existing_hash, status)) = state.db.find_run_by_id(&valid.run_id).map_err(internal)? {
        if existing_hash == valid.submission_hash {
            let run = state.db.run(&valid.run_id).map_err(internal)?;
            return Ok((
                StatusCode::OK,
                axum::Json(SubmitResponse {
                    run_id: valid.run_id,
                    status,
                    segments: sub.segments.len(),
                    batch_id: run.and_then(|r| r.batch_id),
                    duplicate: true,
                }),
            )
                .into_response());
        }
        return Err(fail(
            StatusCode::CONFLICT,
            "run_id already exists with different content",
        ));
    }

    // Persist first, then queue: a crash between the two loses nothing.
    state
        .db
        .insert_run(
            &valid.run_id,
            &id.account,
            sub.player.as_deref(),
            &valid.program.id,
            sub.solo,
            &valid.submission_hash,
            valid.segments.len(),
        )
        .map_err(internal)?;

    for seg in &valid.segments {
        let path = state.segment_proof_path(&valid.run_id, seg.index);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(internal)?;
        }
        std::fs::write(&path, &seg.proof_bytes).map_err(internal)?;
        let args: Vec<String> = seg.args.iter().map(|a| a.to_hex()).collect();
        let preimage: Vec<String> = seg.preimage.iter().map(|a| a.to_hex()).collect();
        let outputs: Vec<String> = seg.output_cells.iter().map(|a| a.to_hex()).collect();
        state
            .db
            .insert_segment(
                &valid.run_id,
                seg.index,
                &seg.leaf_key,
                &serde_json::to_string(&args).map_err(internal)?,
                &serde_json::to_string(&preimage).map_err(internal)?,
                &serde_json::to_string(&outputs).map_err(internal)?,
                Some(&path.to_string_lossy()),
                seg.proof_format.as_str(),
            )
            .map_err(internal)?;
        state
            .db
            .enqueue(
                crate::model::JobKind::Verify,
                &format!("{}:{}", valid.run_id, seg.index),
                Some(&valid.run_id),
                Some(seg.index),
                None,
            )
            .map_err(internal)?;
    }
    state.metrics.incr("wrapper_runs_total", "status=\"received\"");
    state.wake.notify_one();

    let mut status = RunStatus::Verifying.as_str().to_string();
    if q.wait_verify_ms > 0 {
        status = wait_for_verdict(&state, &valid.run_id, q.wait_verify_ms).await;
    }
    let run = state.db.run(&valid.run_id).map_err(internal)?;
    let rejected = run.as_ref().map(|r| r.status == RunStatus::Rejected).unwrap_or(false);
    let body = SubmitResponse {
        run_id: valid.run_id,
        status,
        segments: valid.segments.len(),
        batch_id: run.as_ref().and_then(|r| r.batch_id.clone()),
        duplicate: false,
    };
    let code = if rejected { StatusCode::UNPROCESSABLE_ENTITY } else { StatusCode::ACCEPTED };
    Ok((code, axum::Json(body)).into_response())
}

/// Polls until the run leaves `verifying` (or the budget runs out).
async fn wait_for_verdict(state: &Shared, run_id: &str, budget_ms: u64) -> String {
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(budget_ms);
    loop {
        if let Ok(Some(run)) = state.db.run(run_id) {
            if run.status != RunStatus::Verifying {
                return run.status.as_str().to_string();
            }
        }
        if std::time::Instant::now() >= deadline {
            return RunStatus::Verifying.as_str().to_string();
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

async fn run_status(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<RunStatusResponse>> {
    identify(&state, &headers)?;
    let run = state
        .db
        .run(&id)
        .map_err(internal)?
        .ok_or_else(|| fail(StatusCode::NOT_FOUND, "no such run"))?;
    let segments = state.db.segments(&id).map_err(internal)?;

    let mut out = Vec::with_capacity(segments.len());
    let mut progress = Progress { segments: segments.len(), ..Default::default() };
    let mut timings = Timings::default();
    for seg in &segments {
        let leaf = state.db.leaf(&seg.leaf_key).map_err(internal)?;
        let (leaf_state, leaf_ms, rss) = match &leaf {
            Some(l) => (l.status.clone(), l.duration_ms, l.max_rss_bytes),
            None => ("pending".to_string(), None, None),
        };
        if seg.verified {
            progress.verified += 1;
        }
        if leaf_state == "done" {
            progress.leaves_done += 1;
        }
        timings.verify_ms_total += seg.verify_ms.unwrap_or(0.0);
        timings.leaf_ms_total += leaf_ms.unwrap_or(0.0);
        out.push(SegmentStatus {
            index: seg.idx,
            leaf_key: seg.leaf_key.clone(),
            verified: seg.verified,
            verify_ms: seg.verify_ms,
            leaf_state,
            leaf_ms,
            leaf_max_rss_bytes: rss,
            cached: None,
        });
    }

    let batch = match &run.batch_id {
        Some(b) => state.db.batch(b).map_err(internal)?,
        None => None,
    };
    if let Some(b) = &batch {
        timings.fold_ms = b.fold_ms;
        if let Some(closed) = b.closed_at {
            if let Some(verified) = run.verified_at {
                timings.queued_ms = Some((closed - verified) as f64);
            }
        }
    }
    if run.status.terminal() {
        timings.total_ms = Some((run.updated_at - run.created_at) as f64);
    }

    Ok(axum::Json(RunStatusResponse {
        run_id: run.id,
        status: run.status.as_str().to_string(),
        program: run.program_id,
        player: run.player,
        solo: run.solo,
        batch_id: run.batch_id,
        batch_status: batch.as_ref().map(|b| b.status.as_str().to_string()),
        created_at_ms: run.created_at,
        updated_at_ms: run.updated_at,
        error: run.error,
        progress,
        segments: out,
        timings,
    }))
}

#[derive(Debug, Deserialize, Default)]
pub struct BatchQuery {
    /// `proof` to include the ~94 k root felts, `packed` for the digest tree. Comma separated.
    #[serde(default)]
    pub include: String,
}

async fn batch_status(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(q): Query<BatchQuery>,
) -> ApiResult<axum::Json<BatchResponse>> {
    identify(&state, &headers)?;
    let batch = state
        .db
        .batch(&id)
        .map_err(internal)?
        .ok_or_else(|| fail(StatusCode::NOT_FOUND, "no such batch"))?;
    let want: Vec<&str> = q.include.split(',').map(|s| s.trim()).collect();

    let leaves = state
        .db
        .batch_leaves(&id)
        .map_err(internal)?
        .into_iter()
        .map(|(position, run_id, segment_index, leaf_key)| BatchLeafRef {
            position,
            run_id,
            segment_index,
            leaf_key,
        })
        .collect::<Vec<_>>();

    let mut root_proof_felts = None;
    let mut root_proof_felt_count = None;
    if let Some(path) = &batch.root_path {
        if let Ok(bytes) = std::fs::read(path) {
            if let Ok(felts) = serde_json::from_slice::<Vec<String>>(&bytes) {
                root_proof_felt_count = Some(felts.len());
                if want.contains(&"proof") {
                    root_proof_felts = Some(felts);
                }
            }
        }
    }
    let packed_output = match (&batch.packed_path, want.contains(&"packed") || want.contains(&"proof")) {
        (Some(path), true) => std::fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()),
        _ => None,
    };

    Ok(axum::Json(BatchResponse {
        batch_id: batch.id,
        status: batch.status.as_str().to_string(),
        runs: state.db.batch_runs(&id).map_err(internal)?,
        leaves,
        created_at_ms: batch.created_at,
        closed_at_ms: batch.closed_at,
        finished_at_ms: batch.finished_at,
        fold_ms: batch.fold_ms,
        fold_max_rss_bytes: batch.max_rss_bytes,
        error: batch.error,
        root_proof_felts,
        root_proof_felt_count,
        program_output: batch
            .program_output
            .as_ref()
            .and_then(|s| serde_json::from_str(s).ok()),
        packed_output,
    }))
}

#[derive(Debug, Serialize)]
pub struct CloseResponse {
    pub closed: Vec<String>,
}

/// Admin: closes the open batch now instead of waiting for M runs or T minutes.
async fn close_batches(
    State(state): State<Shared>,
    headers: HeaderMap,
) -> ApiResult<axum::Json<CloseResponse>> {
    let id = identify(&state, &headers)?;
    if !id.admin {
        return Err(fail(StatusCode::FORBIDDEN, "admin key required"));
    }
    let mut closed = vec![];
    if let Some(batch) = state.db.open_batch().map_err(internal)? {
        if state.db.batch_run_count(&batch.id).map_err(internal)? > 0 {
            state.db.close_batch(&batch.id).map_err(internal)?;
            closed.push(batch.id);
        }
    }
    state.wake.notify_one();
    Ok(axum::Json(CloseResponse { closed }))
}

fn internal<E: std::fmt::Display>(e: E) -> Failure {
    Failure(
        StatusCode::INTERNAL_SERVER_ERROR,
        ApiError { error: "internal error".into(), detail: Some(e.to_string()) },
    )
}

/// Used by the README generator and the tests to keep the documented schema honest.
pub fn schema_summary() -> BTreeMap<&'static str, &'static str> {
    BTreeMap::from([
        ("POST /v1/runs", "RunSubmission -> SubmitResponse (202, or 422 when already rejected)"),
        ("GET /v1/runs/{id}", "-> RunStatusResponse"),
        ("GET /v1/batches/{id}", "?include=proof,packed -> BatchResponse"),
        ("POST /v1/batches/close", "admin -> CloseResponse"),
        ("GET /metrics", "Prometheus text"),
        ("GET /healthz", "liveness + effective policy"),
    ])
}
