//! Native reference for the wasm build: runs the *same* execute -> prove -> verify code path
//! (`hellproof_prover_wasm::core`) natively and prints one JSON line with timings, sizes and the
//! peak RSS (`getrusage`). Used by `harness/bench-native.sh`.

use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use hellproof_prover_wasm::core;

#[derive(Parser, Debug)]
#[command(about = "Native reference run of the Hellproof wasm prover code path")]
struct Cli {
    /// Path to the Scarb `*.executable.json`.
    #[arg(long)]
    executable: PathBuf,
    /// Path to the arguments JSON (array of felts). Optional.
    #[arg(long)]
    args: Option<PathBuf>,
    /// Path to a ProverParameters JSON. Defaults to the built-in leaf-format parameters.
    #[arg(long)]
    params: Option<PathBuf>,
    /// rayon thread count (0 = all cores). Use 1 to mimic the single-threaded wasm build.
    #[arg(long, default_value_t = 0)]
    threads: usize,
    /// Write the cairo-serde proof (JSON array of hex felts) to this path.
    #[arg(long)]
    proof_out: Option<PathBuf>,
    /// Skip verification.
    #[arg(long)]
    no_verify: bool,
    /// Extra label copied into the output JSON.
    #[arg(long, default_value = "")]
    label: String,
}

fn max_rss_bytes() -> u64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    // macOS reports bytes, Linux kilobytes.
    if cfg!(target_os = "macos") { ru.ru_maxrss as u64 } else { ru.ru_maxrss as u64 * 1024 }
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    if cli.threads > 0 {
        rayon::ThreadPoolBuilder::new().num_threads(cli.threads).build_global()?;
    }
    let threads = rayon::current_num_threads();

    let executable = std::fs::read_to_string(&cli.executable)?;
    let args = match &cli.args {
        Some(p) => std::fs::read_to_string(p)?,
        None => String::new(),
    };
    let params_json = match &cli.params {
        Some(p) => std::fs::read_to_string(p)?,
        None => String::new(),
    };
    let params = core::parse_params(&params_json)?;

    let t0 = Instant::now();
    let (input, mut stats) = core::execute(&executable, &args)?;
    // Round-trip through bytes exactly like the wasm harness does.
    let input_bytes = core::prover_input_to_bytes(&input)?;
    stats.prover_input_bytes = input_bytes.len();
    drop(input);
    let execute_ms = t0.elapsed().as_secs_f64() * 1e3;
    let rss_after_execute = max_rss_bytes();

    let t1 = Instant::now();
    let input = core::prover_input_from_bytes(&input_bytes)?;
    let (proof_bytes, proof_stats) = core::prove(input, params)?;
    let prove_ms = t1.elapsed().as_secs_f64() * 1e3;
    let rss_after_prove = max_rss_bytes();

    let verify_ms = if cli.no_verify {
        None
    } else {
        let t2 = Instant::now();
        core::verify(&proof_bytes, params)?;
        Some(t2.elapsed().as_secs_f64() * 1e3)
    };

    if let Some(out) = &cli.proof_out {
        let felts = core::proof_to_felts(&proof_bytes, params)?;
        std::fs::write(out, serde_json::to_string(&felts)?)?;
    }

    let result = serde_json::json!({
        "label": cli.label,
        "target": "native",
        "threads": threads,
        "params": core::describe_params(&params),
        "n_steps": stats.n_steps,
        "builtins": stats.builtins,
        "output": stats.output,
        "output_preimage": stats.output_preimage,
        "prover_input_bytes": stats.prover_input_bytes,
        "execute_ms": execute_ms,
        "prove_ms": prove_ms,
        "verify_ms": verify_ms,
        "proof_bytes": proof_stats.proof_bytes,
        "proof_felts": proof_stats.proof_felts,
        "max_log_size": proof_stats.max_log_size,
        "trace_lifting_log_size": proof_stats.trace_lifting_log_size,
        "preprocessed_lifting_log_size": proof_stats.preprocessed_lifting_log_size,
        "max_rss_after_execute_bytes": rss_after_execute,
        "max_rss_after_prove_bytes": rss_after_prove,
        "max_rss_bytes": max_rss_bytes(),
    });
    println!("{result}");
    Ok(())
}
