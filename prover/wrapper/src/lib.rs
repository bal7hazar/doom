// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Hellproof wrapper service (PLAN §1 A4, Phase 3 task 4; G0 D6/D7; RISKS R8).
//!
//! The browser proves each segment of a game; the wrapper turns those segment proofs into **one**
//! root proof that the on-chain circuit verifier accepts. It never touches game logic and never
//! forges: it verifies what it is given, proves leaves with the pinned `leaf-prover`, folds them
//! with the pinned `stwo_run_and_prove_recursive_tree`, and hands back the root proof felts, the
//! packed digest tree and the leaf order.

pub mod api;
pub mod auth;
pub mod batching;
pub mod config;
pub mod db;
pub mod felt;
pub mod metrics;
pub mod model;
pub mod pipeline;
pub mod scheduler;
pub mod validate;

use std::path::PathBuf;
use std::sync::Arc;

use rand::Rng;

use crate::auth::Authenticator;
use crate::batching::Policy;
use crate::config::Config;
use crate::db::Db;
use crate::metrics::Metrics;

pub struct AppState {
    pub cfg: Config,
    pub db: Db,
    pub metrics: Metrics,
    pub auth: Box<dyn Authenticator>,
    pub policy: Policy,
    /// sha256 of the circuit registry in use; part of every leaf key.
    pub registry_hash: String,
    /// Wakes the scheduler as soon as something changed, instead of waiting for the next tick.
    pub wake: tokio::sync::Notify,
    pub started_at_ms: i64,
}

pub type Shared = Arc<AppState>;

impl AppState {
    pub fn new(cfg: Config, db: Db) -> Self {
        let policy = Policy::new(cfg.batch_max_runs, cfg.batch_max_wait_secs);
        let registry_hash = pipeline::registry_hash(&cfg);
        let auth = Box::new(auth::ApiKeyAuth::new(&cfg));
        let started_at_ms = db::now_ms();
        Self {
            cfg,
            db,
            metrics: Metrics::new(),
            auth,
            policy,
            registry_hash,
            wake: tokio::sync::Notify::new(),
            started_at_ms,
        }
    }

    pub fn proofs_dir(&self) -> PathBuf {
        self.cfg.data_dir.join("proofs")
    }
    pub fn leaf_path(&self, leaf_key: &str) -> PathBuf {
        self.proofs_dir().join("leaves").join(format!("{leaf_key}.json"))
    }
    pub fn leaf_work_dir(&self, leaf_key: &str) -> PathBuf {
        self.cfg.data_dir.join("work").join("leaves").join(leaf_key)
    }
    pub fn batch_dir(&self, batch_id: &str) -> PathBuf {
        self.proofs_dir().join("batches").join(batch_id)
    }
    pub fn segment_proof_path(&self, run_id: &str, index: u32) -> PathBuf {
        self.cfg.data_dir.join("submissions").join(run_id).join(format!("segment_{index}.proof"))
    }
}

/// A short, URL-safe, collision-resistant id.
pub fn new_id() -> String {
    let bytes: [u8; 12] = rand::thread_rng().gen();
    hex::encode(bytes)
}
