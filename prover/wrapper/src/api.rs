// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! HTTP surface. See `README.md` for the JSON schema; `client-ts/` mirrors these types.

use std::collections::BTreeMap;
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::auth::Identity;
use crate::db::now_ms;
use crate::felt::Felt;
use crate::model::*;
use crate::{pipeline, validate, Shared};

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
    Failure(
        code,
        ApiError {
            error: msg.into(),
            detail: None,
        },
    )
}

type ApiResult<T> = Result<T, Failure>;

pub fn router(state: Shared) -> Router {
    let body_limit = state.cfg.max_body_bytes;
    Router::new()
        .route("/healthz", get(healthz))
        .route("/metrics", get(metrics))
        .route("/v1/runs", post(submit_run))
        .route("/v1/runs/{id}", get(run_status).delete(delete_run))
        .route("/v1/runs/{id}/segments", get(list_segments))
        .route(
            "/v1/runs/{id}/segments/{index}",
            axum::routing::put(put_segment),
        )
        .route("/v1/runs/{id}/complete", post(complete_run))
        .route("/v1/batches/{id}", get(batch_status))
        .route("/v1/batches/close", post(close_batches))
        // A game's worth of segment proofs is megabytes (3 MB each at 2^20 steps), well over
        // axum's 2 MB default: replace it with our own configured limit.
        .layer(axum::extract::DefaultBodyLimit::disable())
        .layer(tower_http::limit::RequestBodyLimitLayer::new(body_limit))
        .with_state(state)
}

fn identify(state: &Shared, headers: &HeaderMap) -> ApiResult<Identity> {
    let header = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok());
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
        [(
            axum::http::header::CONTENT_TYPE,
            "text/plain; version=0.0.4",
        )],
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

    // No segments: this is the resumable-upload entry point (README "Resumable per-segment
    // uploads") — create the run's metadata now, its segments arrive one by one through
    // `PUT .../segments/{index}`, and `POST .../complete` finishes it. The whole-run path below
    // is unchanged.
    if sub.segments.is_empty() {
        return create_collecting_run(&state, &id, sub).await;
    }

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
    if let Some((existing_hash, status)) =
        state.db.find_run_by_id(&valid.run_id).map_err(internal)?
    {
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
    state
        .metrics
        .incr("wrapper_runs_total", "status=\"received\"");
    state.wake.notify_one();

    let mut status = RunStatus::Verifying.as_str().to_string();
    if q.wait_verify_ms > 0 {
        status = wait_for_verdict(&state, &valid.run_id, q.wait_verify_ms).await;
    }
    let run = state.db.run(&valid.run_id).map_err(internal)?;
    let rejected = run
        .as_ref()
        .map(|r| r.status == RunStatus::Rejected)
        .unwrap_or(false);
    let body = SubmitResponse {
        run_id: valid.run_id,
        status,
        segments: valid.segments.len(),
        batch_id: run.as_ref().and_then(|r| r.batch_id.clone()),
        duplicate: false,
    };
    let code = if rejected {
        StatusCode::UNPROCESSABLE_ENTITY
    } else {
        StatusCode::ACCEPTED
    };
    Ok((code, axum::Json(body)).into_response())
}

/// `POST /v1/runs` with no segments: creates the run's metadata up front (program, player,
/// optional expected segment count) so a client that wants to declare all of that before
/// streaming any proof bytes can. A run can also come into existence without this call at all,
/// from a bare `PUT .../segments/{index}` — the two differ only in whether the program is known
/// before the first segment arrives; `bind_segment_to_program` (deferred to `/complete`) is what
/// actually pins it either way.
async fn create_collecting_run(
    state: &Shared,
    id: &Identity,
    sub: RunSubmission,
) -> ApiResult<Response> {
    let program = state
        .cfg
        .program(&sub.program)
        .ok_or_else(|| {
            fail(
                StatusCode::BAD_REQUEST,
                format!("unknown program `{}`", sub.program),
            )
        })?
        .clone();
    let hash_function = sub.program_hash_function.unwrap_or(program.hash_function);
    if hash_function != program.hash_function {
        return Err(fail(
            StatusCode::BAD_REQUEST,
            format!(
                "program `{}` is configured for program_hash_function `{}`, not `{}`",
                program.id,
                program.hash_function.as_str(),
                hash_function.as_str()
            ),
        ));
    }
    if let Some(p) = &sub.player {
        Felt::parse(p).map_err(|e| {
            fail(
                StatusCode::BAD_REQUEST,
                format!("player is not a felt: {e}"),
            )
        })?;
    }
    if let Some(rid) = &sub.run_id {
        if rid.is_empty()
            || rid.len() > 64
            || !rid
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(fail(
                StatusCode::BAD_REQUEST,
                "run_id must be 1..64 chars of [A-Za-z0-9_-]",
            ));
        }
    }
    if let Some(n) = sub.expected_segments {
        if n == 0 || n as usize > state.cfg.max_segments_per_run {
            return Err(fail(
                StatusCode::BAD_REQUEST,
                format!(
                    "expected_segments must be between 1 and {}",
                    state.cfg.max_segments_per_run
                ),
            ));
        }
    }

    let run_id = sub.run_id.clone().unwrap_or_else(crate::new_id);
    if let Some(existing) = state.db.run(&run_id).map_err(internal)? {
        if existing.account != id.account && !id.admin {
            return Err(fail(
                StatusCode::FORBIDDEN,
                "run_id belongs to another account",
            ));
        }
        // Idempotent, the same way a repeated whole-run POST is: same id, come back with
        // whatever the run is at now instead of erroring or recreating it.
        return Ok((
            StatusCode::OK,
            axum::Json(SubmitResponse {
                run_id: existing.id,
                status: existing.status.as_str().to_string(),
                segments: existing.n_segments,
                batch_id: existing.batch_id,
                duplicate: true,
            }),
        )
            .into_response());
    }

    state
        .db
        .create_collecting_run(
            &run_id,
            &id.account,
            sub.player.as_deref(),
            &program.id,
            sub.solo,
            sub.expected_segments,
        )
        .map_err(internal)?;

    Ok((
        StatusCode::ACCEPTED,
        axum::Json(SubmitResponse {
            run_id,
            status: RunStatus::Collecting.as_str().to_string(),
            segments: 0,
            batch_id: None,
            duplicate: false,
        }),
    )
        .into_response())
}

/// Comma-separated felts from a header, for the raw-bincode `PUT` body (there is no room for a
/// JSON envelope once the body is the proof bytes themselves). Absent header = `None`; present
/// but empty = `Some(vec![])`.
fn header_felts(headers: &HeaderMap, name: &str) -> Option<Vec<String>> {
    let raw = headers.get(name)?.to_str().ok()?;
    if raw.trim().is_empty() {
        return Some(vec![]);
    }
    Some(raw.split(',').map(|s| s.trim().to_string()).collect())
}

/// `PUT /v1/runs/{id}/segments/{index}` — one segment of a resumable upload.
///
/// `Content-Type: application/json` (what the browser client sends today) carries the same shape
/// as one element of a whole-run `POST`'s `segments` array. Anything else is treated as the raw
/// bincode `CairoProof` bytes directly, with `output_preimage` (required), `args` and
/// `public_outputs` (both optional) carried in `X-Hellproof-Output-Preimage`,
/// `X-Hellproof-Args` and `X-Hellproof-Public-Outputs` — comma-separated felts, since a raw body
/// leaves no room for a JSON envelope. Either way this is at most `max_proof_bytes` (a few MB) of
/// one proof, so buffering the request body here never holds more than one proof in memory, the
/// same bound the whole-run `POST` has per segment it streams.
///
/// The proof is verified immediately (R8-A1) — not merely queued — and the verdict is the
/// response. The leaf key (which needs the run's program) is assigned later, at `/complete`.
async fn put_segment(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path((run_id, index)): Path<(String, u32)>,
    body: axum::body::Bytes,
) -> ApiResult<Response> {
    let id = identify(&state, &headers)?;

    if index as usize >= state.cfg.max_segments_per_run {
        return Err(fail(
            StatusCode::BAD_REQUEST,
            format!(
                "segment index {index} is out of range (max_segments_per_run = {})",
                state.cfg.max_segments_per_run
            ),
        ));
    }

    let run = match state.db.run(&run_id).map_err(internal)? {
        Some(r) => r,
        None => {
            state
                .db
                .ensure_collecting_run(&run_id, &id.account)
                .map_err(internal)?;
            state
                .db
                .run(&run_id)
                .map_err(internal)?
                .expect("just inserted")
        }
    };
    if run.account != id.account && !id.admin {
        return Err(fail(
            StatusCode::FORBIDDEN,
            "run belongs to another account",
        ));
    }
    if run.status != RunStatus::Collecting {
        return Err(fail(
            StatusCode::CONFLICT,
            format!(
                "run is `{}`; it is no longer accepting segments",
                run.status.as_str()
            ),
        ));
    }
    if let Some(expected) = run.expected_segments {
        if index >= expected {
            return Err(fail(
                StatusCode::BAD_REQUEST,
                format!(
                    "segment index {index} is out of range: this run expects {expected} segments"
                ),
            ));
        }
    }

    let content_type = headers
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let (args, output_preimage, public_outputs, proof_format, proof_bytes) =
        if content_type.is_empty() || content_type.starts_with("application/json") {
            let seg: SegmentSubmission = serde_json::from_slice(&body)
                .map_err(|e| fail(StatusCode::BAD_REQUEST, format!("invalid JSON body: {e}")))?;
            if seg.index != index {
                return Err(fail(
                    StatusCode::BAD_REQUEST,
                    format!(
                        "body index {} does not match the URL index {index}",
                        seg.index
                    ),
                ));
            }
            let bytes = validate::decode_proof_bytes(&seg.proof, index)
                .map_err(|e| fail(StatusCode::BAD_REQUEST, format!("{e:#}")))?;
            (
                seg.args,
                seg.output_preimage,
                seg.public_outputs,
                seg.proof.format,
                bytes,
            )
        } else {
            let output_preimage = header_felts(&headers, "x-hellproof-output-preimage")
                .ok_or_else(|| {
                    fail(
                        StatusCode::BAD_REQUEST,
                        "missing X-Hellproof-Output-Preimage header",
                    )
                })?;
            let args = header_felts(&headers, "x-hellproof-args").unwrap_or_default();
            let public_outputs =
                header_felts(&headers, "x-hellproof-public-outputs").unwrap_or_default();
            (
                args,
                output_preimage,
                public_outputs,
                ProofFormat::BincodeB64,
                body.to_vec(),
            )
        };

    let shaped = validate::shape_segment(
        index,
        &args,
        &output_preimage,
        &public_outputs,
        proof_format,
        proof_bytes,
        &state.cfg,
    )
    .map_err(|e| fail(StatusCode::BAD_REQUEST, format!("{e:#}")))?;

    let sha256 = hex::encode(Sha256::digest(&shaped.proof_bytes));
    let size_bytes = shaped.proof_bytes.len() as u64;

    // Idempotent by content: the same bytes twice just re-report the verdict; different bytes
    // under an already-held index is a conflict, not a silent overwrite (matches the whole-run
    // `run_id` idempotency rule).
    if let Some(existing) = state.db.segment(&run_id, index).map_err(internal)? {
        if existing.sha256.as_deref() == Some(sha256.as_str()) {
            return Ok((
                StatusCode::OK,
                axum::Json(SegmentUploadResponse {
                    run_id,
                    index,
                    verified: existing.verified,
                    verify_ms: existing.verify_ms,
                    sha256,
                    size_bytes,
                    duplicate: true,
                    error: None,
                }),
            )
                .into_response());
        }
        return Err(fail(
            StatusCode::CONFLICT,
            "segment already uploaded with different content",
        ));
    }

    let path = state.segment_proof_path(&run_id, index);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(internal)?;
    }
    std::fs::write(&path, &shaped.proof_bytes).map_err(internal)?;

    let args_json =
        serde_json::to_string(&shaped.args.iter().map(|a| a.to_hex()).collect::<Vec<_>>())
            .map_err(internal)?;
    let preimage_json = serde_json::to_string(
        &shaped
            .preimage
            .iter()
            .map(|a| a.to_hex())
            .collect::<Vec<_>>(),
    )
    .map_err(internal)?;
    let outputs_json = serde_json::to_string(
        &shaped
            .output_cells
            .iter()
            .map(|a| a.to_hex())
            .collect::<Vec<_>>(),
    )
    .map_err(internal)?;
    state
        .db
        .insert_uploaded_segment(
            &run_id,
            index,
            &args_json,
            &preimage_json,
            &outputs_json,
            &path.to_string_lossy(),
            proof_format.as_str(),
            &sha256,
            size_bytes,
        )
        .map_err(internal)?;

    // R8-A1: verify now, synchronously, rather than merely queueing a `Verify` job — that job
    // exists for the whole-run path; here the endpoint itself is the admission gate.
    let cells = shaped.output_cells;
    let verify_state = Arc::clone(&state);
    let verify_path = path.clone();
    let report = tokio::task::spawn_blocking(move || {
        pipeline::verify_segment_proof(&verify_state.cfg, &verify_path, &cells)
    })
    .await
    .map_err(internal)?
    .map_err(internal)?;
    state.metrics.observe(
        "wrapper_verify_duration_seconds",
        "",
        report.verify_ms / 1e3,
    );

    if !report.ok {
        let msg = report.error.unwrap_or_else(|| "invalid proof".into());
        state
            .db
            .set_run_status(
                &run_id,
                RunStatus::Rejected,
                Some(&format!("segment {index}: {msg}")),
            )
            .map_err(internal)?;
        state
            .metrics
            .incr("wrapper_runs_total", "status=\"rejected\"");
        return Ok((
            StatusCode::UNPROCESSABLE_ENTITY,
            axum::Json(SegmentUploadResponse {
                run_id,
                index,
                verified: false,
                verify_ms: Some(report.verify_ms),
                sha256,
                size_bytes,
                duplicate: false,
                error: Some(msg),
            }),
        )
            .into_response());
    }
    state
        .db
        .mark_segment_verified(&run_id, index, report.verify_ms)
        .map_err(internal)?;
    Ok((
        StatusCode::OK,
        axum::Json(SegmentUploadResponse {
            run_id,
            index,
            verified: true,
            verify_ms: Some(report.verify_ms),
            sha256,
            size_bytes,
            duplicate: false,
            error: None,
        }),
    )
        .into_response())
}

/// `GET /v1/runs/{id}/segments` — what the server holds for a run being assembled by the
/// resumable upload protocol (also answers for a run submitted whole, for consistency).
async fn list_segments(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<SegmentsListResponse>> {
    identify(&state, &headers)?;
    let run = state
        .db
        .run(&id)
        .map_err(internal)?
        .ok_or_else(|| fail(StatusCode::NOT_FOUND, "no such run"))?;
    let segs = state.db.segments(&id).map_err(internal)?;
    let held = segs.iter().map(|s| s.idx).collect();
    let segments = segs
        .iter()
        .map(|s| HeldSegment {
            index: s.idx,
            size_bytes: s.size_bytes.unwrap_or(0),
            sha256: s.sha256.clone().unwrap_or_default(),
            verified: s.verified,
            verify_ms: s.verify_ms,
        })
        .collect();
    Ok(axum::Json(SegmentsListResponse {
        run_id: run.id,
        status: run.status.as_str().to_string(),
        held,
        segments,
        expected_segments: run.expected_segments,
    }))
}

/// `POST /v1/runs/{id}/complete` — finishes a resumable upload: binds every stored segment to the
/// (now known) program, checks the chain across all of them, and queues the run into the
/// batching policy exactly like a full `POST /v1/runs` would.
async fn complete_run(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path(run_id): Path<String>,
    Query(q): Query<SubmitQuery>,
    body: axum::body::Bytes,
) -> ApiResult<Response> {
    let id = identify(&state, &headers)?;
    let req: CompleteRunRequest = if body.is_empty() {
        CompleteRunRequest::default()
    } else {
        serde_json::from_slice(&body)
            .map_err(|e| fail(StatusCode::BAD_REQUEST, format!("invalid JSON body: {e}")))?
    };

    let run = state
        .db
        .run(&run_id)
        .map_err(internal)?
        .ok_or_else(|| fail(StatusCode::NOT_FOUND, "no such run"))?;
    if run.account != id.account && !id.admin {
        return Err(fail(
            StatusCode::FORBIDDEN,
            "run belongs to another account",
        ));
    }

    if run.status != RunStatus::Collecting {
        return already_completed_response(&run);
    }

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

    let program_id = run
        .program_id
        .clone()
        .or_else(|| req.program.clone())
        .ok_or_else(|| {
            fail(
                StatusCode::BAD_REQUEST,
                "`program` is required to complete a run that was created without one",
            )
        })?;
    if let (Some(existing), Some(given)) = (&run.program_id, &req.program) {
        if existing != given {
            return Err(fail(
                StatusCode::BAD_REQUEST,
                format!("run was created for program `{existing}`, not `{given}`"),
            ));
        }
    }
    let program = state
        .cfg
        .program(&program_id)
        .ok_or_else(|| {
            fail(
                StatusCode::BAD_REQUEST,
                format!("unknown program `{program_id}`"),
            )
        })?
        .clone();
    let hash_function = req.program_hash_function.unwrap_or(program.hash_function);
    if hash_function != program.hash_function {
        return Err(fail(
            StatusCode::BAD_REQUEST,
            format!(
                "program `{}` is configured for program_hash_function `{}`, not `{}`",
                program.id,
                program.hash_function.as_str(),
                hash_function.as_str()
            ),
        ));
    }

    let segs = state.db.segments(&run_id).map_err(internal)?;
    if segs.is_empty() {
        return Err(fail(
            StatusCode::BAD_REQUEST,
            "a run needs at least one segment",
        ));
    }
    if let Some(expected) = run.expected_segments {
        if segs.len() as u32 != expected {
            return Err(fail(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("expected {expected} segments, {} uploaded", segs.len()),
            ));
        }
    }

    // Bind every segment to the program (pinned hash + leaf key), and check the chain across all
    // of them — both deferred until now because they need the program, unlike everything
    // `shape_segment` already checked at `PUT` time.
    let mut leaf_keys = Vec::with_capacity(segs.len());
    let mut prev_h_out: Option<Felt> = None;
    let mut hasher = Sha256::new();
    hasher.update(b"hellproof-run-resumable-v1\0");
    hasher.update(program.id.as_bytes());
    hasher.update(b"\0");
    hasher.update(hash_function.as_str().as_bytes());
    for (i, seg) in segs.iter().enumerate() {
        if seg.idx as usize != i {
            return Err(fail(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("segment {i} is missing (indices must be 0..n contiguous)"),
            ));
        }
        let args: Vec<Felt> = parse_felt_json(&seg.args_json).map_err(internal)?;
        let preimage: Vec<Felt> = parse_felt_json(&seg.preimage_json).map_err(internal)?;

        prev_h_out = Some(
            validate::continue_chain(seg.idx, &preimage, &program, prev_h_out)
                .map_err(|e| fail(StatusCode::UNPROCESSABLE_ENTITY, format!("{e:#}")))?,
        );

        let leaf_key = validate::bind_segment_to_program(
            seg.idx,
            &args,
            &preimage,
            &state.cfg,
            &program,
            hash_function,
            &state.registry_hash,
        )
        .map_err(|e| fail(StatusCode::UNPROCESSABLE_ENTITY, format!("{e:#}")))?;
        hasher.update(leaf_key.as_bytes());
        hasher.update(b"\0");
        for f in &preimage {
            hasher.update(f.to_hex().as_bytes());
        }
        hasher.update(seg.sha256.as_deref().unwrap_or("").as_bytes());
        hasher.update(b",");
        leaf_keys.push((seg.idx, leaf_key));
    }
    let submission_hash = hex::encode(hasher.finalize());

    if let Some(p) = req.player.as_deref().or(run.player.as_deref()) {
        Felt::parse(p).map_err(|e| {
            fail(
                StatusCode::BAD_REQUEST,
                format!("player is not a felt: {e}"),
            )
        })?;
    }

    for (idx, key) in &leaf_keys {
        state
            .db
            .set_segment_leaf_key(&run_id, *idx, key)
            .map_err(internal)?;
    }
    let finalized = state
        .db
        .finalize_collecting_run(
            &run_id,
            req.player.as_deref(),
            &program.id,
            req.solo,
            &submission_hash,
            segs.len(),
        )
        .map_err(internal)?;
    if !finalized {
        // Lost a race with a concurrent `PUT` that rejected the run in between: answer with
        // whatever it is now instead of pretending we completed it.
        let run = state
            .db
            .run(&run_id)
            .map_err(internal)?
            .ok_or_else(|| fail(StatusCode::NOT_FOUND, "no such run"))?;
        return already_completed_response(&run);
    }

    state
        .metrics
        .incr("wrapper_runs_total", "status=\"received\"");
    state.wake.notify_one();

    let mut status = RunStatus::Verifying.as_str().to_string();
    if q.wait_verify_ms > 0 {
        status = wait_for_verdict(&state, &run_id, q.wait_verify_ms).await;
    }
    let refreshed = state.db.run(&run_id).map_err(internal)?;
    let rejected = refreshed
        .as_ref()
        .map(|r| r.status == RunStatus::Rejected)
        .unwrap_or(false);
    let body = SubmitResponse {
        run_id: run_id.clone(),
        status,
        segments: segs.len(),
        batch_id: refreshed.as_ref().and_then(|r| r.batch_id.clone()),
        duplicate: false,
    };
    let code = if rejected {
        StatusCode::UNPROCESSABLE_ENTITY
    } else {
        StatusCode::ACCEPTED
    };
    Ok((code, axum::Json(body)).into_response())
}

/// `/complete` called again on a run that already left `collecting`: answer idempotently (like a
/// repeated whole-run `POST` with the same `run_id`), or with the stored rejection.
fn already_completed_response(run: &crate::db::RunRow) -> ApiResult<Response> {
    if run.status == RunStatus::Rejected {
        return Err(fail(
            StatusCode::UNPROCESSABLE_ENTITY,
            run.error.clone().unwrap_or_else(|| "rejected".into()),
        ));
    }
    Ok((
        StatusCode::OK,
        axum::Json(SubmitResponse {
            run_id: run.id.clone(),
            status: run.status.as_str().to_string(),
            segments: run.n_segments,
            batch_id: run.batch_id.clone(),
            duplicate: true,
        }),
    )
        .into_response())
}

fn parse_felt_json(json: &str) -> anyhow::Result<Vec<Felt>> {
    let hexes: Vec<String> = serde_json::from_str(json)?;
    hexes.iter().map(|h| Felt::parse(h)).collect()
}

/// `DELETE /v1/runs/{id}` — only ever an unfinished (`collecting`) run: nothing has been queued
/// for it yet, so deleting it is just forgetting its rows and its proof files.
async fn delete_run(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path(run_id): Path<String>,
) -> ApiResult<StatusCode> {
    let id = identify(&state, &headers)?;
    let run = state
        .db
        .run(&run_id)
        .map_err(internal)?
        .ok_or_else(|| fail(StatusCode::NOT_FOUND, "no such run"))?;
    if run.account != id.account && !id.admin {
        return Err(fail(
            StatusCode::FORBIDDEN,
            "run belongs to another account",
        ));
    }
    if run.status != RunStatus::Collecting {
        return Err(fail(
            StatusCode::CONFLICT,
            format!(
                "run is `{}`; only an unfinished (collecting) run can be deleted",
                run.status.as_str()
            ),
        ));
    }
    let deleted = state.db.delete_collecting_run(&run_id).map_err(internal)?;
    if deleted {
        let dir = state.cfg.data_dir.join("submissions").join(&run_id);
        let _ = std::fs::remove_dir_all(dir);
    }
    Ok(StatusCode::NO_CONTENT)
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
    let mut progress = Progress {
        segments: segments.len(),
        ..Default::default()
    };
    let mut timings = Timings::default();
    for seg in &segments {
        let leaf = match &seg.leaf_key {
            Some(key) => state.db.leaf(key).map_err(internal)?,
            None => None,
        };
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
            leaf_key: seg.leaf_key.clone().unwrap_or_default(),
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
        program: run.program_id.unwrap_or_default(),
        player: run.player,
        solo: run.solo,
        expected_segments: run.expected_segments,
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
    let packed_output = match (
        &batch.packed_path,
        want.contains(&"packed") || want.contains(&"proof"),
    ) {
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
        ApiError {
            error: "internal error".into(),
            detail: Some(e.to_string()),
        },
    )
}

/// Used by the README generator and the tests to keep the documented schema honest.
pub fn schema_summary() -> BTreeMap<&'static str, &'static str> {
    BTreeMap::from([
        (
            "POST /v1/runs",
            "RunSubmission -> SubmitResponse (202, or 422 when already rejected); empty \
             `segments` creates a `collecting` run instead",
        ),
        ("GET /v1/runs/{id}", "-> RunStatusResponse"),
        (
            "DELETE /v1/runs/{id}",
            "an unfinished (`collecting`) run only -> 204",
        ),
        (
            "GET /v1/runs/{id}/segments",
            "-> SegmentsListResponse (what the server holds)",
        ),
        (
            "PUT /v1/runs/{id}/segments/{index}",
            "one segment (JSON or raw bincode) -> SegmentUploadResponse, verified immediately",
        ),
        (
            "POST /v1/runs/{id}/complete",
            "CompleteRunRequest -> SubmitResponse, same semantics as a whole-run POST",
        ),
        (
            "GET /v1/batches/{id}",
            "?include=proof,packed -> BatchResponse",
        ),
        ("POST /v1/batches/close", "admin -> CloseResponse"),
        ("GET /metrics", "Prometheus text"),
        ("GET /healthz", "liveness + effective policy"),
    ])
}
