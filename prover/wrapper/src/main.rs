// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use hellproof_wrapper::config::Config;
use hellproof_wrapper::db::Db;
use hellproof_wrapper::scheduler::Scheduler;
use hellproof_wrapper::{api, AppState};

#[derive(Parser, Debug)]
#[command(about = "Hellproof wrapper service: segment proofs in, one root proof out")]
struct Cli {
    /// TOML configuration (see `wrapper.example.toml`).
    #[arg(long, default_value = "wrapper.toml")]
    config: PathBuf,
    /// Validate the configuration and exit.
    #[arg(long)]
    check: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::load(&cli.config)?;
    cfg.check_runnable()?;
    if cli.check {
        println!("configuration OK");
        return Ok(());
    }
    std::fs::create_dir_all(&cfg.data_dir)
        .with_context(|| format!("cannot create {}", cfg.data_dir.display()))?;

    let db = Db::open(&cfg.data_dir.join("queue.sqlite3"))?;
    let requeued = db.recover()?;
    if requeued > 0 {
        tracing::warn!(
            jobs = requeued,
            "re-queued jobs that were running before the restart"
        );
    }

    let bind = cfg.bind.clone();
    let state = Arc::new(AppState::new(cfg, db));
    tokio::spawn(Scheduler::new(Arc::clone(&state)).run());

    let app = api::router(Arc::clone(&state));
    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .with_context(|| format!("cannot bind {bind}"))?;
    tracing::info!(
        addr = %listener.local_addr()?,
        registry = %state.registry_hash,
        max_circuit_proofs = state.cfg.effective_max_circuit_proofs(),
        batch_max_runs = state.policy.max_runs,
        batch_max_wait_ms = state.policy.max_wait_ms,
        "wrapper listening"
    );
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
            tracing::info!("shutting down; queued work resumes on the next start");
        })
        .await?;
    Ok(())
}
