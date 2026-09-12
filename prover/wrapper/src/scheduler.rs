// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! The job scheduler: one supervisor task plus a bounded pool of blocking workers.
//!
//! Everything it does is derived from the database, so the process can be killed at any point and
//! restarted: `Db::recover()` re-queues whatever was running, and the loop below re-derives which
//! batches must close, which leaves are missing and which folds are ready.
//!
//! Resource rule: a circuit proof — leaf **or** fold — peaks at the configured registry's
//! `circuit_proof_rss_bytes` (32.1–32.5 GB on `doom`, 21.9 GB on `doom_fold4_min`), so
//! `max_circuit_proofs` — derived from that and the machine's memory unless set — gates both kinds
//! through one semaphore. Verification is cheap and has its own, wider, gate.

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use tokio::sync::Semaphore;

use crate::db::now_ms;
use crate::model::{BatchStatus, Job, JobKind, JobState, RunStatus};
use crate::{Shared, pipeline};

pub struct Scheduler {
    state: Shared,
    circuit_slots: Arc<Semaphore>,
    verify_slots: Arc<Semaphore>,
}

impl Scheduler {
    pub fn new(state: Shared) -> Self {
        let circuit = state.cfg.effective_max_circuit_proofs();
        let verify = state.cfg.max_verify_jobs.max(1);
        Self {
            state,
            circuit_slots: Arc::new(Semaphore::new(circuit)),
            verify_slots: Arc::new(Semaphore::new(verify)),
        }
    }

    /// Runs until cancelled.
    pub async fn run(self) {
        let tick = Duration::from_millis(self.state.cfg.scheduler_tick_ms.max(50));
        loop {
            if let Err(e) = self.step().await {
                tracing::error!("scheduler step failed: {e:#}");
            }
            tokio::select! {
                _ = tokio::time::sleep(tick) => {}
                _ = self.state.wake.notified() => {}
            }
        }
    }

    /// One pass: promote runs, close batches, queue folds, dispatch work.
    pub async fn step(&self) -> Result<()> {
        self.promote_verified_runs()?;
        self.close_due_batches()?;
        self.queue_ready_folds()?;
        self.propagate_failures()?;
        self.export_queue_metrics()?;
        self.dispatch().await?;
        Ok(())
    }

    /// A run whose every segment proof verified joins a batch (D6) and its leaves are queued.
    fn promote_verified_runs(&self) -> Result<()> {
        let db = &self.state.db;
        for run_id in db.runs_with_status("verifying")? {
            if !db.all_segments_verified(&run_id)? {
                continue;
            }
            let Some(run) = db.run(&run_id)? else { continue };
            let open = db.open_batch()?;
            let placement =
                self.state.policy.place(run.solo, now_ms(), open.as_ref().map(|b| b.id.as_str()));
            let batch_id = match placement {
                crate::batching::Placement::Existing(id) => id,
                crate::batching::Placement::New { solo, close_deadline } => {
                    let id = crate::new_id();
                    db.create_batch(&id, solo, close_deadline)?;
                    self.state.metrics.incr("wrapper_batches_opened_total", "");
                    id
                }
            };
            db.assign_run_to_batch(&run_id, &batch_id)?;
            self.state.metrics.incr("wrapper_runs_total", "status=\"queued\"");
            tracing::info!(run = %run_id, batch = %batch_id, solo = run.solo, "run verified and batched");

            for seg in db.segments(&run_id)? {
                if db.ensure_leaf(&seg.leaf_key)? {
                    // Already proven for another run (or an earlier submission of this one).
                    self.state.metrics.incr("wrapper_leaf_cache_hits_total", "");
                    continue;
                }
                db.enqueue_leaf(&seg.leaf_key, &run_id, seg.idx)?;
            }

            // Close as soon as the batch is full, so a burst of submissions produces batches of
            // exactly M runs instead of one oversized batch.
            let count = db.batch_run_count(&batch_id)?;
            let deadline = db.batch(&batch_id)?.and_then(|b| b.close_deadline);
            if self.state.policy.should_close(run.solo, count, deadline, now_ms()) {
                self.close(&batch_id)?;
            }
        }
        Ok(())
    }

    fn close_due_batches(&self) -> Result<()> {
        for id in self.state.db.batches_to_close(self.state.cfg.batch_max_runs)? {
            self.close(&id)?;
        }
        Ok(())
    }

    fn close(&self, batch_id: &str) -> Result<()> {
        let leaves = self.state.db.close_batch(batch_id)?;
        self.state.metrics.incr("wrapper_batches_closed_total", "");
        self.state.metrics.observe("wrapper_batch_leaves", "", leaves.len() as f64);
        tracing::info!(batch = %batch_id, leaves = leaves.len(), "batch closed");
        Ok(())
    }

    fn queue_ready_folds(&self) -> Result<()> {
        let db = &self.state.db;
        for id in db.closed_batches()? {
            if db.batch_leaves_ready(&id)? {
                db.enqueue(JobKind::Fold, &id, None, None, Some(&id))?;
            }
        }
        Ok(())
    }

    /// A leaf that failed for good fails every run that needs it (and their batch).
    fn propagate_failures(&self) -> Result<()> {
        let db = &self.state.db;
        for (run_id, leaf_key, error) in db.runs_blocked_by_failed_leaf()? {
            let msg = format!("leaf {leaf_key} failed: {error}");
            if let Some(run) = db.run(&run_id)? {
                if let Some(batch) = run.batch_id.as_deref() {
                    let b = db.batch(batch)?;
                    if matches!(b.map(|b| b.status), Some(BatchStatus::Closed) | Some(BatchStatus::Folding)) {
                        db.fail_batch(batch, &msg)?;
                        continue;
                    }
                }
                db.set_run_status(&run_id, RunStatus::Failed, Some(&msg))?;
            }
        }
        Ok(())
    }

    fn export_queue_metrics(&self) -> Result<()> {
        let m = &self.state.metrics;
        for (kind, state, n) in self.state.db.queue_depths()? {
            m.set("wrapper_queue_depth", &format!("kind=\"{kind}\",state=\"{state}\""), n as f64);
        }
        for (status, n) in self.state.db.run_counts()? {
            m.set("wrapper_runs", &format!("status=\"{status}\""), n as f64);
        }
        Ok(())
    }

    /// Claims as many jobs as there are free slots and runs each on a blocking thread.
    async fn dispatch(&self) -> Result<()> {
        // Verification first: it is what turns a submission into a rejection quickly (R8-A1).
        let free = self.verify_slots.available_permits();
        for job in self.state.db.claim(&[JobKind::Verify], free)? {
            let permit = Arc::clone(&self.verify_slots).acquire_owned().await?;
            self.spawn(job, permit);
        }
        let free = self.circuit_slots.available_permits();
        // Folds before leaves: a closed batch is the critical path, and a fold that is ready
        // means every one of its leaves is already done.
        for job in self.state.db.claim(&[JobKind::Fold, JobKind::Leaf], free)? {
            let permit = Arc::clone(&self.circuit_slots).acquire_owned().await?;
            self.spawn(job, permit);
        }
        Ok(())
    }

    fn spawn(&self, job: Job, permit: tokio::sync::OwnedSemaphorePermit) {
        let state = Arc::clone(&self.state);
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let kind = job.kind;
            let started = std::time::Instant::now();
            let outcome = run_job(&state, &job);
            let secs = started.elapsed().as_secs_f64();
            let labels = format!("kind=\"{}\"", kind.as_str());
            state.metrics.observe("wrapper_job_duration_seconds", &labels, secs);
            match outcome {
                Ok(()) => {
                    let _ = state.db.finish_job(job.id, JobState::Done, None);
                    state.metrics.incr(
                        "wrapper_jobs_total",
                        &format!("kind=\"{}\",outcome=\"done\"", kind.as_str()),
                    );
                }
                Err(e) => {
                    let msg = format!("{e:#}");
                    tracing::warn!(job = job.id, kind = kind.as_str(), "job failed: {msg}");
                    if job.attempts < state.cfg.job_max_attempts && kind != JobKind::Verify {
                        let _ = state.db.requeue_job(job.id, &msg);
                        state.metrics.incr(
                            "wrapper_jobs_total",
                            &format!("kind=\"{}\",outcome=\"retry\"", kind.as_str()),
                        );
                    } else {
                        let _ = state.db.finish_job(job.id, JobState::Failed, Some(&msg));
                        state.metrics.incr(
                            "wrapper_jobs_total",
                            &format!("kind=\"{}\",outcome=\"failed\"", kind.as_str()),
                        );
                        let _ = fail_job_subject(&state, &job, &msg);
                    }
                }
            }
            state.wake.notify_one();
        });
    }
}

/// Marks what a permanently failed job blocks.
fn fail_job_subject(state: &Shared, job: &Job, error: &str) -> Result<()> {
    match job.kind {
        JobKind::Verify => {
            if let Some(run) = &job.run_id {
                state.db.set_run_status(run, RunStatus::Rejected, Some(error))?;
            }
        }
        JobKind::Leaf => {
            state.db.set_leaf_status(
                &leaf_key_of(state, job)?,
                "failed",
                None,
                None,
                None,
                Some(error),
            )?;
        }
        JobKind::Fold => {
            if let Some(batch) = &job.batch_id {
                state.db.fail_batch(batch, error)?;
            }
        }
    }
    Ok(())
}

fn leaf_key_of(state: &Shared, job: &Job) -> Result<String> {
    let run = job.run_id.clone().unwrap_or_default();
    let idx = job.seg_index.unwrap_or(0);
    let seg = state
        .db
        .segment(&run, idx)?
        .ok_or_else(|| anyhow::anyhow!("job {} references an unknown segment", job.id))?;
    Ok(seg.leaf_key)
}

fn run_job(state: &Shared, job: &Job) -> Result<()> {
    match job.kind {
        JobKind::Verify => verify_job(state, job),
        JobKind::Leaf => leaf_job(state, job),
        JobKind::Fold => fold_job(state, job),
    }
}

/// R8-A1: the Rust verifier on the submitted segment proof, before any expensive work.
fn verify_job(state: &Shared, job: &Job) -> Result<()> {
    let run_id = job.run_id.clone().ok_or_else(|| anyhow::anyhow!("verify job without a run"))?;
    let idx = job.seg_index.ok_or_else(|| anyhow::anyhow!("verify job without a segment"))?;
    let seg = state
        .db
        .segment(&run_id, idx)?
        .ok_or_else(|| anyhow::anyhow!("unknown segment {run_id}/{idx}"))?;
    if seg.verified {
        return Ok(());
    }
    let cells: Vec<crate::felt::Felt> = {
        let hexes: Vec<String> = serde_json::from_str(&seg.outputs_json)?;
        hexes.iter().map(|h| crate::felt::Felt::parse(h)).collect::<Result<_>>()?
    };
    let cells: [crate::felt::Felt; 2] = [cells[0], cells[1]];

    let proof_path = seg
        .proof_path
        .clone()
        .ok_or_else(|| anyhow::anyhow!("segment {run_id}/{idx} has no stored proof"))?;
    let report = pipeline::verify_segment_proof(&state.cfg, std::path::Path::new(&proof_path), &cells)?;
    state
        .metrics
        .observe("wrapper_verify_duration_seconds", "", report.verify_ms / 1e3);
    if !report.ok {
        let msg = report.error.unwrap_or_else(|| "invalid proof".into());
        state.db.set_run_status(&run_id, RunStatus::Rejected, Some(&format!("segment {idx}: {msg}")))?;
        state.metrics.incr("wrapper_runs_total", "status=\"rejected\"");
        // The job itself did its work: the answer is "no".
        return Ok(());
    }
    state.db.mark_segment_verified(&run_id, idx, report.verify_ms)?;
    Ok(())
}

/// `leaf-prover` on one segment: 22 s / 32.5 GB (S4).
fn leaf_job(state: &Shared, job: &Job) -> Result<()> {
    let leaf_key = leaf_key_of(state, job)?;
    if let Some(leaf) = state.db.leaf(&leaf_key)? {
        if leaf.status == "done" {
            return Ok(());
        }
    }
    let run_id = job.run_id.clone().unwrap_or_default();
    let idx = job.seg_index.unwrap_or(0);
    let seg = state
        .db
        .segment(&run_id, idx)?
        .ok_or_else(|| anyhow::anyhow!("unknown segment {run_id}/{idx}"))?;
    let run = state.db.run(&run_id)?.ok_or_else(|| anyhow::anyhow!("unknown run {run_id}"))?;
    let program = state
        .cfg
        .program(&run.program_id)
        .ok_or_else(|| anyhow::anyhow!("program `{}` is no longer configured", run.program_id))?;

    let args: Vec<crate::felt::Felt> = {
        let hexes: Vec<String> = serde_json::from_str(&seg.args_json)?;
        hexes.iter().map(|h| crate::felt::Felt::parse(h)).collect::<Result<_>>()?
    };

    state.db.set_leaf_status(&leaf_key, "running", None, None, None, None)?;
    let out = pipeline::prove_leaf(
        &state.cfg,
        &program.executable,
        program.hash_function,
        &args,
        &state.leaf_work_dir(&leaf_key),
        &state.leaf_path(&leaf_key),
    )?;

    // The bootloader's own preimage must be the one the client submitted, or the leaf would fold
    // into a different digest than the client (and the contract) expects.
    if state.cfg.check_preimage_binding && state.cfg.backend != crate::config::Backend::Stub {
        let claimed: Vec<String> = serde_json::from_str(&seg.preimage_json)?;
        if claimed != out.preimage {
            anyhow::bail!(
                "the bootloader dumped a different output preimage than the submission: \
                 {:?} vs {:?}",
                out.preimage,
                claimed
            );
        }
    }

    state.db.set_leaf_status(
        &leaf_key,
        "done",
        Some(&out.proof_path.to_string_lossy()),
        Some(out.resources.duration_ms),
        Some(out.resources.max_rss_bytes),
        None,
    )?;
    state
        .metrics
        .set_max("wrapper_job_max_rss_bytes", "kind=\"leaf\"", out.resources.max_rss_bytes as f64);
    tracing::info!(
        leaf = %leaf_key,
        ms = out.resources.duration_ms,
        rss = out.resources.max_rss_bytes,
        "leaf proven"
    );
    Ok(())
}

/// `stwo_run_and_prove_recursive_tree` on a closed batch.
fn fold_job(state: &Shared, job: &Job) -> Result<()> {
    let batch_id = job.batch_id.clone().ok_or_else(|| anyhow::anyhow!("fold job without a batch"))?;
    let leaves = state.db.batch_leaves(&batch_id)?;
    if leaves.is_empty() {
        anyhow::bail!("batch {batch_id} has no leaves");
    }
    let mut paths = Vec::with_capacity(leaves.len());
    for (_, _, _, key) in &leaves {
        let leaf = state
            .db
            .leaf(key)?
            .ok_or_else(|| anyhow::anyhow!("leaf {key} is missing"))?;
        let path = leaf
            .proof_path
            .ok_or_else(|| anyhow::anyhow!("leaf {key} has no proof file"))?;
        paths.push(std::path::PathBuf::from(path));
    }
    state.db.set_batch_status(&batch_id, BatchStatus::Folding, None)?;
    let out = pipeline::fold_batch(&state.cfg, &paths, &state.batch_dir(&batch_id))?;

    // Self-check: recompute the root's output words from the leaves' preimages the way the
    // on-chain consumer will (`recursion_outputs::fold_tree`). If they disagree, the batch is
    // not what it says it is and must not be handed to a client.
    if state.cfg.backend != crate::config::Backend::Stub {
        let packed: serde_json::Value = serde_json::from_slice(&std::fs::read(&out.packed_path)?)?;
        let (preimages, leaf_hash, mv_hash) = crate::recompose::parse_packed_output(&packed)?;
        let root = crate::recompose::root_from_preimages(&preimages, leaf_hash, mv_hash)
            .ok_or_else(|| anyhow::anyhow!("empty packed output"))?;
        let claimed: Vec<u32> = serde_json::from_value(out.program_output.clone())?;
        if claimed != root.output {
            anyhow::bail!(
                "the tree's program_output {:?} is not the recomposition of the leaves {:?}",
                claimed,
                root.output
            );
        }
        tracing::info!(
            batch = %batch_id,
            output_hash = ?crate::recompose::verification_output_hash(&root),
            "root recomposition checks out"
        );
    }

    state.db.finish_batch(
        &batch_id,
        &out.root_path.to_string_lossy(),
        &out.packed_path.to_string_lossy(),
        &serde_json::to_string(&out.program_output)?,
        out.resources.duration_ms,
        Some(out.resources.max_rss_bytes),
    )?;
    state
        .metrics
        .set_max("wrapper_job_max_rss_bytes", "kind=\"fold\"", out.resources.max_rss_bytes as f64);
    state.metrics.observe("wrapper_root_proof_felts", "", out.root_felt_count as f64);
    tracing::info!(
        batch = %batch_id,
        leaves = leaves.len(),
        ms = out.resources.duration_ms,
        felts = out.root_felt_count,
        "batch folded"
    );
    Ok(())
}
