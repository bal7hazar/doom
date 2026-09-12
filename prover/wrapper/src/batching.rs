// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Batching policy (G0 decision D6, risk R7-A3).
//!
//! One root proof can carry the segments of several games, so the on-chain cost per game is
//! divided by the number of games in the batch. The wait must be **bounded and visible**: a batch
//! closes when it holds `max_runs` games **or** when `max_wait` has elapsed since the batch was
//! opened — whichever comes first — and a player who does not want to wait submits with
//! `solo: true` and gets a batch of their own, closed immediately.
//!
//! These are pure functions: the scheduler and the tests use the same code.

/// What to do with a freshly verified run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Placement {
    /// Put it in the existing open batch.
    Existing(String),
    /// Open a new batch. `solo` batches are closed as soon as the run joins them.
    New { solo: bool, close_deadline: Option<i64> },
}

#[derive(Debug, Clone, Copy)]
pub struct Policy {
    /// M — a batch closes at this many runs.
    pub max_runs: usize,
    /// T, in milliseconds — a batch closes this long after it opened.
    pub max_wait_ms: i64,
}

impl Policy {
    pub fn new(max_runs: usize, max_wait_secs: u64) -> Self {
        Self { max_runs: max_runs.max(1), max_wait_ms: (max_wait_secs as i64) * 1000 }
    }

    /// Where a run goes. `open` is the current open shared batch, if any.
    pub fn place(&self, solo: bool, now_ms: i64, open: Option<&str>) -> Placement {
        if solo {
            return Placement::New { solo: true, close_deadline: Some(now_ms) };
        }
        match open {
            Some(id) => Placement::Existing(id.to_string()),
            None => Placement::New { solo: false, close_deadline: Some(now_ms + self.max_wait_ms) },
        }
    }

    /// Whether an open batch must close now.
    pub fn should_close(&self, solo: bool, run_count: usize, close_deadline: Option<i64>, now_ms: i64) -> bool {
        if run_count == 0 {
            return false;
        }
        if solo {
            return true;
        }
        if run_count >= self.max_runs {
            return true;
        }
        matches!(close_deadline, Some(t) if now_ms >= t)
    }

    /// Milliseconds left before the deadline forces a close (for the client's progress view).
    pub fn wait_remaining_ms(&self, close_deadline: Option<i64>, now_ms: i64) -> Option<i64> {
        close_deadline.map(|t| (t - now_ms).max(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_000_000;

    fn policy() -> Policy {
        // The documented defaults: M = 8 runs, T = 10 minutes.
        Policy::new(8, 600)
    }

    #[test]
    fn defaults_are_m8_t10min() {
        let p = policy();
        assert_eq!(p.max_runs, 8);
        assert_eq!(p.max_wait_ms, 600_000);
    }

    #[test]
    fn first_run_opens_a_batch_with_a_deadline() {
        assert_eq!(
            policy().place(false, T0, None),
            Placement::New { solo: false, close_deadline: Some(T0 + 600_000) }
        );
    }

    #[test]
    fn later_runs_join_the_open_batch() {
        assert_eq!(policy().place(false, T0, Some("b1")), Placement::Existing("b1".into()));
    }

    #[test]
    fn solo_always_gets_its_own_batch_closed_now() {
        let p = policy();
        assert_eq!(
            p.place(true, T0, Some("b1")),
            Placement::New { solo: true, close_deadline: Some(T0) }
        );
        assert!(p.should_close(true, 1, Some(T0), T0));
    }

    #[test]
    fn closes_at_m_runs_before_the_deadline() {
        let p = policy();
        assert!(!p.should_close(false, 7, Some(T0 + 600_000), T0));
        assert!(p.should_close(false, 8, Some(T0 + 600_000), T0));
    }

    #[test]
    fn closes_at_the_deadline_with_fewer_runs() {
        let p = policy();
        assert!(!p.should_close(false, 1, Some(T0 + 600_000), T0 + 599_999));
        assert!(p.should_close(false, 1, Some(T0 + 600_000), T0 + 600_000));
    }

    #[test]
    fn never_closes_an_empty_batch() {
        assert!(!policy().should_close(false, 0, Some(T0 - 1), T0));
    }

    #[test]
    fn reports_the_remaining_wait() {
        let p = policy();
        assert_eq!(p.wait_remaining_ms(Some(T0 + 1000), T0), Some(1000));
        assert_eq!(p.wait_remaining_ms(Some(T0 - 1000), T0), Some(0));
        assert_eq!(p.wait_remaining_ms(None, T0), None);
    }

    #[test]
    fn m_of_one_wraps_every_run_alone() {
        let p = Policy::new(1, 600);
        assert!(p.should_close(false, 1, Some(T0 + 600_000), T0));
    }
}
