// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Shared helpers: a wrapper wired to the `stub` backend, driven through its real HTTP router
//! and its real scheduler, so the queue, the batching policy and the API are exercised together
//! without spending 32.5 GB on a circuit proof.

#![allow(dead_code)]

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use hellproof_wrapper::config::{ApiKey, Backend, Config, ProgramEntry};
use hellproof_wrapper::db::Db;
use hellproof_wrapper::scheduler::Scheduler;
use hellproof_wrapper::{api, AppState, Shared};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

pub const KEY: &str = "test-key";
pub const ADMIN_KEY: &str = "test-admin";

pub struct Harness {
    pub state: Shared,
    pub router: Router,
    pub _dir: tempfile::TempDir,
}

pub fn config(dir: &std::path::Path, batch_max_runs: usize, batch_max_wait_secs: u64) -> Config {
    let mut cfg = Config::default();
    cfg.data_dir = dir.to_path_buf();
    cfg.backend = Backend::Stub;
    cfg.batch_max_runs = batch_max_runs;
    cfg.batch_max_wait_secs = batch_max_wait_secs;
    cfg.scheduler_tick_ms = 20;
    cfg.max_circuit_proofs = Some(2);
    cfg.programs.push(ProgramEntry {
        id: "segment_stub".into(),
        executable: dir.join("segment_stub.executable.json"),
        program_hash: None,
        hash_function: Default::default(),
    });
    cfg.api_keys.push(ApiKey {
        key: KEY.into(),
        account: "0xabc".into(),
        admin: false,
        daily_run_quota: 0,
    });
    cfg.api_keys.push(ApiKey {
        key: ADMIN_KEY.into(),
        account: "0xdef".into(),
        admin: true,
        daily_run_quota: 0,
    });
    cfg
}

impl Harness {
    /// Builds a wrapper and starts its scheduler.
    pub fn start(batch_max_runs: usize, batch_max_wait_secs: u64) -> Self {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("segment_stub.executable.json"), b"{}").unwrap();
        let cfg = config(dir.path(), batch_max_runs, batch_max_wait_secs);
        let db = Db::open(&dir.path().join("queue.sqlite3")).unwrap();
        db.recover().unwrap();
        let state = Arc::new(AppState::new(cfg, db));
        tokio::spawn(Scheduler::new(Arc::clone(&state)).run());
        let router = api::router(Arc::clone(&state));
        Self {
            state,
            router,
            _dir: dir,
        }
    }

    pub async fn call(&self, req: Request<Body>) -> (StatusCode, Value) {
        let res = self.router.clone().oneshot(req).await.unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, value)
    }

    pub async fn submit(&self, body: Value) -> (StatusCode, Value) {
        self.submit_as(KEY, body).await
    }

    pub async fn submit_as(&self, key: &str, body: Value) -> (StatusCode, Value) {
        let req = Request::builder()
            .method("POST")
            .uri("/v1/runs")
            .header("authorization", format!("Bearer {key}"))
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_vec(&body).unwrap()))
            .unwrap();
        self.call(req).await
    }

    pub async fn get(&self, uri: &str) -> (StatusCode, Value) {
        let req = Request::builder()
            .uri(uri)
            .header("authorization", format!("Bearer {KEY}"))
            .body(Body::empty())
            .unwrap();
        self.call(req).await
    }

    pub async fn close_batches(&self) -> (StatusCode, Value) {
        let req = Request::builder()
            .method("POST")
            .uri("/v1/batches/close")
            .header("authorization", format!("Bearer {ADMIN_KEY}"))
            .body(Body::empty())
            .unwrap();
        self.call(req).await
    }

    /// Waits until a run reaches one of `statuses`, or panics after `timeout_ms`.
    pub async fn wait_run(&self, run_id: &str, statuses: &[&str], timeout_ms: u64) -> Value {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);
        loop {
            let (_, v) = self.get(&format!("/v1/runs/{run_id}")).await;
            let status = v["status"].as_str().unwrap_or("").to_string();
            if statuses.contains(&status.as_str()) {
                return v;
            }
            if std::time::Instant::now() > deadline {
                panic!("run {run_id} stuck in `{status}` (wanted {statuses:?}): {v}");
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    }
}

/// A submission body whose segments chain `h_in`/`h_out` the way `segment_stub` does.
pub fn run_body(seed: u64, n_segments: u32, solo: bool) -> Value {
    let mut segments = vec![];
    let mut h = seed + 1;
    for i in 0..n_segments {
        let h_in = h;
        let h_out = h * 31 + 7;
        h = h_out;
        segments.push(json!({
            "index": i,
            "args": [format!("0x{h_in:x}"), format!("0x{:x}", 250 + i)],
            "output_preimage": [
                "0x5",
                format!("0x{h_in:x}"),
                format!("0x{h_out:x}"),
                format!("0x{:x}", 250 + i),
                "0x0"
            ],
            "proof": {
                "format": "bincode_b64",
                "data": base64_of(&format!("proof-{seed}-{i}"))
            }
        }));
    }
    json!({ "program": "segment_stub", "solo": solo, "segments": segments })
}

fn base64_of(s: &str) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(s.as_bytes())
}
