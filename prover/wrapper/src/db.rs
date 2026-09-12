// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! The persistent queue (R8-A2): SQLite, WAL, one connection behind a mutex.
//!
//! Every state transition goes through this module, so a restart loses nothing: `recover()`
//! re-queues jobs that were running when the process died and re-opens the batch clock.

use std::path::Path;
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, params};

use crate::model::{BatchStatus, Job, JobKind, JobState, RunStatus};

pub struct Db {
    conn: Mutex<Connection>,
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS runs (
  id              TEXT PRIMARY KEY,
  account         TEXT NOT NULL,
  player          TEXT,
  program_id      TEXT NOT NULL,
  solo            INTEGER NOT NULL DEFAULT 0,
  status          TEXT NOT NULL,
  batch_id        TEXT,
  submission_hash TEXT NOT NULL,
  n_segments      INTEGER NOT NULL,
  error           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  verified_at     INTEGER
);
CREATE INDEX IF NOT EXISTS runs_status ON runs(status);
CREATE INDEX IF NOT EXISTS runs_batch ON runs(batch_id);

CREATE TABLE IF NOT EXISTS segments (
  run_id          TEXT NOT NULL,
  idx             INTEGER NOT NULL,
  leaf_key        TEXT NOT NULL,
  args_json       TEXT NOT NULL,
  preimage_json   TEXT NOT NULL,
  outputs_json    TEXT NOT NULL,
  proof_path      TEXT,
  proof_format    TEXT NOT NULL,
  verified        INTEGER NOT NULL DEFAULT 0,
  verify_ms       REAL,
  PRIMARY KEY (run_id, idx)
);
CREATE INDEX IF NOT EXISTS segments_leaf ON segments(leaf_key);

-- Content-addressed leaf proofs: the same (registry, program, args) is never proven twice
-- (R8-A3, idempotence by hash).
CREATE TABLE IF NOT EXISTS leaves (
  leaf_key        TEXT PRIMARY KEY,
  status          TEXT NOT NULL,
  proof_path      TEXT,
  duration_ms     REAL,
  max_rss_bytes   INTEGER,
  error           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS batches (
  id               TEXT PRIMARY KEY,
  status           TEXT NOT NULL,
  solo             INTEGER NOT NULL DEFAULT 0,
  close_deadline   INTEGER,
  created_at       INTEGER NOT NULL,
  closed_at        INTEGER,
  finished_at      INTEGER,
  root_path        TEXT,
  packed_path      TEXT,
  program_output   TEXT,
  fold_ms          REAL,
  max_rss_bytes    INTEGER,
  error            TEXT
);
CREATE INDEX IF NOT EXISTS batches_status ON batches(status);

CREATE TABLE IF NOT EXISTS batch_leaves (
  batch_id        TEXT NOT NULL,
  position        INTEGER NOT NULL,
  run_id          TEXT NOT NULL,
  seg_index       INTEGER NOT NULL,
  leaf_key        TEXT NOT NULL,
  PRIMARY KEY (batch_id, position)
);

CREATE TABLE IF NOT EXISTS jobs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  kind            TEXT NOT NULL,
  dedup_key       TEXT NOT NULL,
  state           TEXT NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  run_id          TEXT,
  seg_index       INTEGER,
  batch_id        TEXT,
  error           TEXT,
  created_at      INTEGER NOT NULL,
  started_at      INTEGER,
  finished_at     INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS jobs_dedup ON jobs(kind, dedup_key);
CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state, kind);
"#;

impl Db {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)
            .with_context(|| format!("cannot open {}", path.display()))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    pub fn open_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// After a restart: jobs that were `running` did not finish, so they go back to `queued`
    /// (their attempt already counted). Returns how many were re-queued.
    pub fn recover(&self) -> Result<usize> {
        let conn = self.lock();
        let n = conn.execute(
            "UPDATE jobs SET state = 'queued', started_at = NULL WHERE state = 'running'",
            [],
        )?;
        // A batch caught mid-fold restarts the fold from its (re-queued) job.
        conn.execute("UPDATE batches SET status = 'closed' WHERE status = 'folding'", [])?;
        // A leaf caught mid-proof is not trusted: its job is queued again, so is its row.
        conn.execute(
            "UPDATE leaves SET status = 'queued' WHERE status = 'running'",
            [],
        )?;
        Ok(n)
    }

    // ---- runs -------------------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    pub fn insert_run(
        &self,
        id: &str,
        account: &str,
        player: Option<&str>,
        program_id: &str,
        solo: bool,
        submission_hash: &str,
        n_segments: usize,
    ) -> Result<()> {
        let now = now_ms();
        self.lock().execute(
            "INSERT INTO runs (id, account, player, program_id, solo, status, submission_hash,
                               n_segments, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 'verifying', ?6, ?7, ?8, ?8)",
            params![id, account, player, program_id, solo as i64, submission_hash, n_segments as i64, now],
        )?;
        Ok(())
    }

    pub fn find_run_by_id(&self, id: &str) -> Result<Option<(String, String)>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT submission_hash, status FROM runs WHERE id = ?1",
                params![id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        Ok(row)
    }

    pub fn set_run_status(&self, id: &str, status: RunStatus, error: Option<&str>) -> Result<()> {
        self.lock().execute(
            "UPDATE runs SET status = ?2, error = COALESCE(?3, error), updated_at = ?4 WHERE id = ?1",
            params![id, status.as_str(), error, now_ms()],
        )?;
        Ok(())
    }

    pub fn runs_with_status(&self, status: &str) -> Result<Vec<String>> {
        let conn = self.lock();
        let mut stmt = conn.prepare("SELECT id FROM runs WHERE status = ?1 ORDER BY created_at, id")?;
        let rows = stmt.query_map(params![status], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Runs that can never complete because one of their leaves failed for good.
    pub fn runs_blocked_by_failed_leaf(&self) -> Result<Vec<(String, String, String)>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT s.run_id, s.leaf_key, COALESCE(l.error, 'unknown error')
             FROM segments s
             JOIN leaves l ON l.leaf_key = s.leaf_key
             JOIN runs r ON r.id = s.run_id
             WHERE l.status = 'failed' AND r.status NOT IN ('failed', 'rejected', 'done')
             GROUP BY s.run_id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn runs_submitted_since(&self, account: &str, since_ms: i64) -> Result<u32> {
        let conn = self.lock();
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM runs WHERE account = ?1 AND created_at >= ?2",
            params![account, since_ms],
            |r| r.get(0),
        )?;
        Ok(n as u32)
    }

    // ---- segments ---------------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    pub fn insert_segment(
        &self,
        run_id: &str,
        idx: u32,
        leaf_key: &str,
        args_json: &str,
        preimage_json: &str,
        outputs_json: &str,
        proof_path: Option<&str>,
        proof_format: &str,
    ) -> Result<()> {
        self.lock().execute(
            "INSERT INTO segments (run_id, idx, leaf_key, args_json, preimage_json, outputs_json,
                                   proof_path, proof_format)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![run_id, idx, leaf_key, args_json, preimage_json, outputs_json, proof_path, proof_format],
        )?;
        Ok(())
    }

    pub fn mark_segment_verified(&self, run_id: &str, idx: u32, verify_ms: f64) -> Result<()> {
        self.lock().execute(
            "UPDATE segments SET verified = 1, verify_ms = ?3 WHERE run_id = ?1 AND idx = ?2",
            params![run_id, idx, verify_ms],
        )?;
        Ok(())
    }

    pub fn segment(&self, run_id: &str, idx: u32) -> Result<Option<SegmentRow>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT idx, leaf_key, args_json, preimage_json, outputs_json, proof_path,
                        proof_format, verified, verify_ms
                 FROM segments WHERE run_id = ?1 AND idx = ?2",
                params![run_id, idx],
                segment_row,
            )
            .optional()?;
        Ok(row)
    }

    pub fn segments(&self, run_id: &str) -> Result<Vec<SegmentRow>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT idx, leaf_key, args_json, preimage_json, outputs_json, proof_path,
                    proof_format, verified, verify_ms
             FROM segments WHERE run_id = ?1 ORDER BY idx",
        )?;
        let rows = stmt.query_map(params![run_id], segment_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn all_segments_verified(&self, run_id: &str) -> Result<bool> {
        let conn = self.lock();
        let pending: i64 = conn.query_row(
            "SELECT COUNT(*) FROM segments WHERE run_id = ?1 AND verified = 0",
            params![run_id],
            |r| r.get(0),
        )?;
        Ok(pending == 0)
    }

    // ---- leaves -----------------------------------------------------------------------------

    pub fn leaf(&self, key: &str) -> Result<Option<LeafRow>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT leaf_key, status, proof_path, duration_ms, max_rss_bytes, error
                 FROM leaves WHERE leaf_key = ?1",
                params![key],
                |r| {
                    Ok(LeafRow {
                        leaf_key: r.get(0)?,
                        status: r.get(1)?,
                        proof_path: r.get(2)?,
                        duration_ms: r.get(3)?,
                        max_rss_bytes: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                        error: r.get(5)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    /// Registers a leaf if it is unknown. Returns true when the leaf already had a proof (cache
    /// hit) and no work needs to be scheduled.
    pub fn ensure_leaf(&self, key: &str) -> Result<bool> {
        let now = now_ms();
        let conn = self.lock();
        conn.execute(
            "INSERT OR IGNORE INTO leaves (leaf_key, status, created_at, updated_at)
             VALUES (?1, 'queued', ?2, ?2)",
            params![key, now],
        )?;
        let status: String =
            conn.query_row("SELECT status FROM leaves WHERE leaf_key = ?1", params![key], |r| r.get(0))?;
        Ok(status == "done")
    }

    pub fn set_leaf_status(
        &self,
        key: &str,
        status: &str,
        proof_path: Option<&str>,
        duration_ms: Option<f64>,
        max_rss: Option<u64>,
        error: Option<&str>,
    ) -> Result<()> {
        self.lock().execute(
            "UPDATE leaves SET status = ?2, proof_path = COALESCE(?3, proof_path),
                    duration_ms = COALESCE(?4, duration_ms),
                    max_rss_bytes = COALESCE(?5, max_rss_bytes),
                    error = ?6, updated_at = ?7
             WHERE leaf_key = ?1",
            params![key, status, proof_path, duration_ms, max_rss.map(|v| v as i64), error, now_ms()],
        )?;
        Ok(())
    }

    // ---- batches ----------------------------------------------------------------------------

    /// The open batch, if any (there is at most one non-solo open batch at a time).
    pub fn open_batch(&self) -> Result<Option<BatchRow>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT id, status, solo, close_deadline, created_at, closed_at, finished_at,
                        root_path, packed_path, program_output, fold_ms, max_rss_bytes, error
                 FROM batches WHERE status = 'open' AND solo = 0 ORDER BY created_at LIMIT 1",
                [],
                batch_row,
            )
            .optional()?;
        Ok(row)
    }

    pub fn batch(&self, id: &str) -> Result<Option<BatchRow>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT id, status, solo, close_deadline, created_at, closed_at, finished_at,
                        root_path, packed_path, program_output, fold_ms, max_rss_bytes, error
                 FROM batches WHERE id = ?1",
                params![id],
                batch_row,
            )
            .optional()?;
        Ok(row)
    }

    pub fn create_batch(&self, id: &str, solo: bool, close_deadline: Option<i64>) -> Result<()> {
        self.lock().execute(
            "INSERT INTO batches (id, status, solo, close_deadline, created_at)
             VALUES (?1, 'open', ?2, ?3, ?4)",
            params![id, solo as i64, close_deadline, now_ms()],
        )?;
        Ok(())
    }

    pub fn assign_run_to_batch(&self, run_id: &str, batch_id: &str) -> Result<()> {
        self.lock().execute(
            "UPDATE runs SET batch_id = ?2, status = 'queued', verified_at = ?3, updated_at = ?3
             WHERE id = ?1",
            params![run_id, batch_id, now_ms()],
        )?;
        Ok(())
    }

    pub fn batch_run_count(&self, batch_id: &str) -> Result<usize> {
        let conn = self.lock();
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM runs WHERE batch_id = ?1",
            params![batch_id],
            |r| r.get(0),
        )?;
        Ok(n as usize)
    }

    pub fn batch_runs(&self, batch_id: &str) -> Result<Vec<String>> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare("SELECT id FROM runs WHERE batch_id = ?1 ORDER BY verified_at, created_at, id")?;
        let rows = stmt.query_map(params![batch_id], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn set_batch_status(&self, id: &str, status: BatchStatus, error: Option<&str>) -> Result<()> {
        self.lock().execute(
            "UPDATE batches SET status = ?2, error = COALESCE(?3, error) WHERE id = ?1",
            params![id, status.as_str(), error],
        )?;
        Ok(())
    }

    /// Freezes the batch's fold order: runs in the order they were verified, segments in index
    /// order. This list is what the on-chain consumer needs to map leaves back to players.
    pub fn close_batch(&self, id: &str) -> Result<Vec<(u32, String, u32, String)>> {
        let runs = self.batch_runs(id)?;
        let mut leaves = Vec::new();
        let mut position = 0u32;
        for run_id in &runs {
            for seg in self.segments(run_id)? {
                leaves.push((position, run_id.clone(), seg.idx, seg.leaf_key.clone()));
                position += 1;
            }
        }
        let conn = self.lock();
        let tx = conn.unchecked_transaction()?;
        for (pos, run_id, idx, key) in &leaves {
            tx.execute(
                "INSERT OR REPLACE INTO batch_leaves (batch_id, position, run_id, seg_index, leaf_key)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, pos, run_id, idx, key],
            )?;
        }
        tx.execute(
            "UPDATE batches SET status = 'closed', closed_at = ?2 WHERE id = ?1",
            params![id, now_ms()],
        )?;
        tx.execute(
            "UPDATE runs SET status = 'wrapping', updated_at = ?2 WHERE batch_id = ?1 AND status = 'queued'",
            params![id, now_ms()],
        )?;
        tx.commit()?;
        Ok(leaves)
    }

    pub fn batch_leaves(&self, id: &str) -> Result<Vec<(u32, String, u32, String)>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT position, run_id, seg_index, leaf_key FROM batch_leaves
             WHERE batch_id = ?1 ORDER BY position",
        )?;
        let rows = stmt.query_map(params![id], |r| {
            Ok((r.get::<_, u32>(0)?, r.get::<_, String>(1)?, r.get::<_, u32>(2)?, r.get::<_, String>(3)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// True when every leaf of the batch has a proof.
    pub fn batch_leaves_ready(&self, id: &str) -> Result<bool> {
        let conn = self.lock();
        let pending: i64 = conn.query_row(
            "SELECT COUNT(*) FROM batch_leaves bl
             LEFT JOIN leaves l ON l.leaf_key = bl.leaf_key
             WHERE bl.batch_id = ?1 AND (l.status IS NULL OR l.status != 'done')",
            params![id],
            |r| r.get(0),
        )?;
        Ok(pending == 0)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn finish_batch(
        &self,
        id: &str,
        root_path: &str,
        packed_path: &str,
        program_output: &str,
        fold_ms: f64,
        max_rss: Option<u64>,
    ) -> Result<()> {
        let now = now_ms();
        let conn = self.lock();
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "UPDATE batches SET status = 'done', root_path = ?2, packed_path = ?3,
                    program_output = ?4, fold_ms = ?5, max_rss_bytes = ?6, finished_at = ?7
             WHERE id = ?1",
            params![id, root_path, packed_path, program_output, fold_ms, max_rss.map(|v| v as i64), now],
        )?;
        tx.execute(
            "UPDATE runs SET status = 'done', updated_at = ?2 WHERE batch_id = ?1",
            params![id, now],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn fail_batch(&self, id: &str, error: &str) -> Result<()> {
        let now = now_ms();
        let conn = self.lock();
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "UPDATE batches SET status = 'failed', error = ?2, finished_at = ?3 WHERE id = ?1",
            params![id, error, now],
        )?;
        tx.execute(
            "UPDATE runs SET status = 'failed', error = ?2, updated_at = ?3 WHERE batch_id = ?1",
            params![id, error, now],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Batches that should close now: full (M runs) or past their deadline (T minutes).
    pub fn batches_to_close(&self, max_runs: usize) -> Result<Vec<String>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT b.id FROM batches b
             WHERE b.status = 'open'
               AND ( (b.close_deadline IS NOT NULL AND b.close_deadline <= ?1)
                     OR (SELECT COUNT(*) FROM runs r WHERE r.batch_id = b.id) >= ?2 )
               AND (SELECT COUNT(*) FROM runs r WHERE r.batch_id = b.id) > 0",
        )?;
        let rows = stmt.query_map(params![now_ms(), max_runs as i64], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn closed_batches(&self) -> Result<Vec<String>> {
        let conn = self.lock();
        let mut stmt = conn.prepare("SELECT id FROM batches WHERE status = 'closed'")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    // ---- jobs -------------------------------------------------------------------------------

    pub fn enqueue(
        &self,
        kind: JobKind,
        dedup_key: &str,
        run_id: Option<&str>,
        seg_index: Option<u32>,
        batch_id: Option<&str>,
    ) -> Result<()> {
        self.lock().execute(
            "INSERT OR IGNORE INTO jobs (kind, dedup_key, state, run_id, seg_index, batch_id, created_at)
             VALUES (?1, ?2, 'queued', ?3, ?4, ?5, ?6)",
            params![kind.as_str(), dedup_key, run_id, seg_index, batch_id, now_ms()],
        )?;
        Ok(())
    }

    /// Queues a leaf proof. A leaf shared by several runs is proven once: the dedup key is the
    /// leaf key. A previously finished (or failed) job for the same leaf is cleared first, so a
    /// retry after a transient failure is possible.
    pub fn enqueue_leaf(&self, leaf_key: &str, run_id: &str, seg_index: u32) -> Result<()> {
        let conn = self.lock();
        conn.execute(
            "DELETE FROM jobs WHERE kind = 'leaf' AND dedup_key = ?1 AND state IN ('done','failed')",
            params![leaf_key],
        )?;
        conn.execute(
            "INSERT OR IGNORE INTO jobs (kind, dedup_key, state, run_id, seg_index, created_at)
             VALUES ('leaf', ?1, 'queued', ?2, ?3, ?4)",
            params![leaf_key, run_id, seg_index, now_ms()],
        )?;
        Ok(())
    }

    /// Claims up to `limit` queued jobs of the given kinds, marking them `running`.
    pub fn claim(&self, kinds: &[JobKind], limit: usize) -> Result<Vec<Job>> {
        if limit == 0 || kinds.is_empty() {
            return Ok(vec![]);
        }
        let list: Vec<&str> = kinds.iter().map(|k| k.as_str()).collect();
        let placeholders = list.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let conn = self.lock();
        let tx = conn.unchecked_transaction()?;
        let sql = format!(
            "SELECT id, kind, run_id, seg_index, batch_id, attempts FROM jobs
             WHERE state = 'queued' AND kind IN ({placeholders}) ORDER BY id LIMIT {limit}"
        );
        let jobs: Vec<Job> = {
            let mut stmt = tx.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(list.iter()), |r| {
                Ok(Job {
                    id: r.get(0)?,
                    kind: JobKind::parse(&r.get::<_, String>(1)?).unwrap_or(JobKind::Verify),
                    run_id: r.get(2)?,
                    seg_index: r.get(3)?,
                    batch_id: r.get(4)?,
                    // Reported as the attempt this claim *is*, not the count before it.
                    attempts: r.get::<_, u32>(5)? + 1,
                })
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        for job in &jobs {
            tx.execute(
                "UPDATE jobs SET state = 'running', attempts = attempts + 1, started_at = ?2
                 WHERE id = ?1",
                params![job.id, now_ms()],
            )?;
        }
        tx.commit()?;
        Ok(jobs)
    }

    pub fn finish_job(&self, id: i64, state: JobState, error: Option<&str>) -> Result<()> {
        self.lock().execute(
            "UPDATE jobs SET state = ?2, error = ?3, finished_at = ?4 WHERE id = ?1",
            params![id, state.as_str(), error, now_ms()],
        )?;
        Ok(())
    }

    pub fn requeue_job(&self, id: i64, error: &str) -> Result<()> {
        self.lock().execute(
            "UPDATE jobs SET state = 'queued', error = ?2, started_at = NULL WHERE id = ?1",
            params![id, error],
        )?;
        Ok(())
    }

    /// Queue depth per (kind, state), for the metrics endpoint.
    pub fn queue_depths(&self) -> Result<Vec<(String, String, i64)>> {
        let conn = self.lock();
        let mut stmt =
            conn.prepare("SELECT kind, state, COUNT(*) FROM jobs GROUP BY kind, state")?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn run_counts(&self) -> Result<Vec<(String, i64)>> {
        let conn = self.lock();
        let mut stmt = conn.prepare("SELECT status, COUNT(*) FROM runs GROUP BY status")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn run(&self, id: &str) -> Result<Option<RunRow>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT id, account, player, program_id, solo, status, batch_id, n_segments,
                        error, created_at, updated_at, verified_at
                 FROM runs WHERE id = ?1",
                params![id],
                |r| {
                    Ok(RunRow {
                        id: r.get(0)?,
                        account: r.get(1)?,
                        player: r.get(2)?,
                        program_id: r.get(3)?,
                        solo: r.get::<_, i64>(4)? != 0,
                        status: RunStatus::parse(&r.get::<_, String>(5)?),
                        batch_id: r.get(6)?,
                        n_segments: r.get::<_, i64>(7)? as usize,
                        error: r.get(8)?,
                        created_at: r.get(9)?,
                        updated_at: r.get(10)?,
                        verified_at: r.get(11)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }
}

#[derive(Debug, Clone)]
pub struct RunRow {
    pub id: String,
    pub account: String,
    pub player: Option<String>,
    pub program_id: String,
    pub solo: bool,
    pub status: RunStatus,
    pub batch_id: Option<String>,
    pub n_segments: usize,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub verified_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct SegmentRow {
    pub idx: u32,
    pub leaf_key: String,
    pub args_json: String,
    pub preimage_json: String,
    pub outputs_json: String,
    pub proof_path: Option<String>,
    pub proof_format: String,
    pub verified: bool,
    pub verify_ms: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct LeafRow {
    pub leaf_key: String,
    pub status: String,
    pub proof_path: Option<String>,
    pub duration_ms: Option<f64>,
    pub max_rss_bytes: Option<u64>,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct BatchRow {
    pub id: String,
    pub status: BatchStatus,
    pub solo: bool,
    pub close_deadline: Option<i64>,
    pub created_at: i64,
    pub closed_at: Option<i64>,
    pub finished_at: Option<i64>,
    pub root_path: Option<String>,
    pub packed_path: Option<String>,
    pub program_output: Option<String>,
    pub fold_ms: Option<f64>,
    pub max_rss_bytes: Option<u64>,
    pub error: Option<String>,
}

fn segment_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<SegmentRow> {
    Ok(SegmentRow {
        idx: r.get(0)?,
        leaf_key: r.get(1)?,
        args_json: r.get(2)?,
        preimage_json: r.get(3)?,
        outputs_json: r.get(4)?,
        proof_path: r.get(5)?,
        proof_format: r.get(6)?,
        verified: r.get::<_, i64>(7)? != 0,
        verify_ms: r.get(8)?,
    })
}

fn batch_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<BatchRow> {
    Ok(BatchRow {
        id: r.get(0)?,
        status: BatchStatus::parse(&r.get::<_, String>(1)?),
        solo: r.get::<_, i64>(2)? != 0,
        close_deadline: r.get(3)?,
        created_at: r.get(4)?,
        closed_at: r.get(5)?,
        finished_at: r.get(6)?,
        root_path: r.get(7)?,
        packed_path: r.get(8)?,
        program_output: r.get(9)?,
        fold_ms: r.get(10)?,
        max_rss_bytes: r.get::<_, Option<i64>>(11)?.map(|v| v as u64),
        error: r.get(12)?,
    })
}
