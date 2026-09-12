// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Prometheus text exposition (R8-A5: durations, RSS, queue depth), hand-rolled so the service
//! carries no metrics dependency.

use std::collections::BTreeMap;
use std::sync::Mutex;

/// Duration buckets in seconds, chosen around the measured pipeline: verification ~0.05 s, a leaf
/// ~22 s, a fold ~30 s per reduction, a 50-leaf batch ~45 min.
const BUCKETS: &[f64] = &[
    0.05, 0.25, 1.0, 5.0, 15.0, 30.0, 60.0, 120.0, 300.0, 900.0, 3600.0,
];

#[derive(Default)]
struct Histogram {
    counts: Vec<u64>,
    sum: f64,
    total: u64,
}

impl Histogram {
    fn observe(&mut self, v: f64) {
        if self.counts.is_empty() {
            self.counts = vec![0; BUCKETS.len()];
        }
        for (i, b) in BUCKETS.iter().enumerate() {
            if v <= *b {
                self.counts[i] += 1;
            }
        }
        self.sum += v;
        self.total += 1;
    }
}

#[derive(Default)]
struct Inner {
    counters: BTreeMap<(&'static str, String), u64>,
    gauges: BTreeMap<(&'static str, String), f64>,
    histograms: BTreeMap<(&'static str, String), Histogram>,
}

#[derive(Default)]
pub struct Metrics {
    inner: Mutex<Inner>,
}

impl Metrics {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn incr(&self, name: &'static str, labels: &str) {
        *self
            .lock()
            .counters
            .entry((name, labels.to_string()))
            .or_default() += 1;
    }

    pub fn set(&self, name: &'static str, labels: &str, value: f64) {
        self.lock().gauges.insert((name, labels.to_string()), value);
    }

    /// Keeps the largest value ever seen (used for peak RSS).
    pub fn set_max(&self, name: &'static str, labels: &str, value: f64) {
        let mut inner = self.lock();
        let e = inner
            .gauges
            .entry((name, labels.to_string()))
            .or_insert(0.0);
        if value > *e {
            *e = value;
        }
    }

    pub fn observe(&self, name: &'static str, labels: &str, seconds: f64) {
        self.lock()
            .histograms
            .entry((name, labels.to_string()))
            .or_default()
            .observe(seconds);
    }

    /// Renders the Prometheus text format (version 0.0.4).
    pub fn render(&self) -> String {
        let inner = self.lock();
        let mut out = String::new();
        let mut seen: Vec<&str> = vec![];

        for ((name, labels), value) in &inner.counters {
            if !seen.contains(name) {
                out.push_str(&format!("# TYPE {name} counter\n"));
                seen.push(name);
            }
            out.push_str(&format!("{name}{}{} {value}\n", fmt_labels(labels), ""));
        }
        for ((name, labels), value) in &inner.gauges {
            if !seen.contains(name) {
                out.push_str(&format!("# TYPE {name} gauge\n"));
                seen.push(name);
            }
            out.push_str(&format!("{name}{} {value}\n", fmt_labels(labels)));
        }
        for ((name, labels), h) in &inner.histograms {
            if !seen.contains(name) {
                out.push_str(&format!("# TYPE {name} histogram\n"));
                seen.push(name);
            }
            for (i, b) in BUCKETS.iter().enumerate() {
                let count = h.counts.get(i).copied().unwrap_or(0);
                out.push_str(&format!(
                    "{name}_bucket{} {count}\n",
                    fmt_labels_with(labels, &format!("le=\"{b}\""))
                ));
            }
            out.push_str(&format!(
                "{name}_bucket{} {}\n",
                fmt_labels_with(labels, "le=\"+Inf\""),
                h.total
            ));
            out.push_str(&format!("{name}_sum{} {}\n", fmt_labels(labels), h.sum));
            out.push_str(&format!("{name}_count{} {}\n", fmt_labels(labels), h.total));
        }
        out
    }
}

fn fmt_labels(labels: &str) -> String {
    if labels.is_empty() {
        String::new()
    } else {
        format!("{{{labels}}}")
    }
}

fn fmt_labels_with(labels: &str, extra: &str) -> String {
    if labels.is_empty() {
        format!("{{{extra}}}")
    } else {
        format!("{{{labels},{extra}}}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_counters_gauges_and_histograms() {
        let m = Metrics::new();
        m.incr("wrapper_jobs_total", "kind=\"leaf\",outcome=\"done\"");
        m.incr("wrapper_jobs_total", "kind=\"leaf\",outcome=\"done\"");
        m.set("wrapper_queue_depth", "kind=\"leaf\",state=\"queued\"", 3.0);
        m.set_max("wrapper_job_max_rss_bytes", "kind=\"leaf\"", 1000.0);
        m.set_max("wrapper_job_max_rss_bytes", "kind=\"leaf\"", 500.0);
        m.observe("wrapper_job_duration_seconds", "kind=\"leaf\"", 22.0);

        let text = m.render();
        assert!(text.contains("wrapper_jobs_total{kind=\"leaf\",outcome=\"done\"} 2"));
        assert!(text.contains("wrapper_queue_depth{kind=\"leaf\",state=\"queued\"} 3"));
        assert!(text.contains("wrapper_job_max_rss_bytes{kind=\"leaf\"} 1000"));
        assert!(text.contains("wrapper_job_duration_seconds_bucket{kind=\"leaf\",le=\"30\"} 1"));
        assert!(text.contains("wrapper_job_duration_seconds_bucket{kind=\"leaf\",le=\"15\"} 0"));
        assert!(text.contains("wrapper_job_duration_seconds_count{kind=\"leaf\"} 1"));
        assert!(text.contains("# TYPE wrapper_job_duration_seconds histogram"));
    }
}
