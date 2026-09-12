//! Hellproof prover — WASM64 (Memory64) build of the Stwo Cairo prover.
//!
//! The wasm ABI is hand-written (no wasm-bindgen: its Memory64 support is recent and its
//! `--target web` glue has not been validated on this toolchain, see README). It follows the
//! approach of `clealabs/stwo-cairo-ts`:
//!
//! * the host allocates input buffers in linear memory with `alloc(len) -> ptr` and frees them
//!   with `dealloc(ptr, len)`;
//! * every entry point takes `(ptr, len)` pairs and returns a pointer to a [`ResultHeader`]
//!   (five little-endian u64: status, info_ptr, info_len, data_ptr, data_len) that the host reads
//!   and then releases with `free_result(ptr)`;
//! * `info` is a UTF-8 JSON string (stats on success, message on error); `data` is the payload.
//!
//! Imports (module `host`): `log(level, ptr, len)`, `random(ptr, len)`, `now() -> f64` (ms), and
//! — in the threaded build only — `spawn_thread(ptr)`.
//! On wasm64 every pointer/length is an `i64` at the JS boundary (BigInt).
//!
//! Two artifacts are built from this source (see `build.sh`):
//!
//! * the **single-threaded** one (default): private linear memory, no atomics — the fallback when
//!   the page is not `crossOriginIsolated`;
//! * the **threaded** one (`THREADS=1`): `+atomics`, `--shared-memory --import-memory`, memory
//!   supplied by JS as a shared `WebAssembly.Memory`. `init_thread_pool(n)` builds rayon's global
//!   pool with a spawn handler that hands each rayon thread body to the host
//!   (`host.spawn_thread`); the host starts a Worker which instantiates *this same module* on the
//!   *same* memory, points `__stack_pointer` at a freshly allocated stack, initializes its TLS
//!   block with `__wasm_init_tls` and calls [`worker_entry`]. Rust statics live in the shared
//!   linear memory, so all threads see the same allocator, the same tracing subscriber and the
//!   same rayon registry, exactly as natively.

pub mod core;

#[cfg(target_arch = "wasm64")]
mod wasm {
    use std::alloc::{Layout, alloc as sys_alloc, dealloc as sys_dealloc};
    use std::panic;
    use std::sync::Once;

    use tracing::Subscriber;
    use tracing::span::{Attributes, Id};
    use tracing_subscriber::Layer;
    use tracing_subscriber::layer::{Context, SubscriberExt};
    use tracing_subscriber::registry::LookupSpan;
    use tracing_subscriber::util::SubscriberInitExt;

    use crate::core;

    #[link(wasm_import_module = "host")]
    unsafe extern "C" {
        fn log(level: u32, ptr: *const u8, len: usize);
        fn random(ptr: *mut u8, len: usize);
        fn now() -> f64;
    }

    /// Threaded build only: asks the host to start a Worker for one rayon thread. The host must
    /// queue the Worker before returning (the calling thread then blocks until it registers).
    #[cfg(target_feature = "atomics")]
    #[link(wasm_import_module = "host")]
    unsafe extern "C" {
        fn spawn_thread(ptr: usize);
    }

    const LOG_ERROR: u32 = 0;
    const LOG_WARN: u32 = 1;
    const LOG_INFO: u32 = 2;
    const LOG_DEBUG: u32 = 3;

    fn host_log(level: u32, msg: &str) {
        unsafe { log(level, msg.as_ptr(), msg.len()) }
    }

    // ---- getrandom custom backends -------------------------------------------------------------

    /// getrandom 0.3 / 0.4 with `--cfg getrandom_backend="custom"` (both versions resolve this
    /// exact symbol name).
    #[unsafe(no_mangle)]
    unsafe extern "Rust" fn __getrandom_v03_custom(
        dest: *mut u8,
        len: usize,
    ) -> Result<(), getrandom_v3::Error> {
        unsafe { random(dest, len) };
        Ok(())
    }

    /// getrandom 0.2 with the `custom` feature.
    fn getrandom_v2_custom(buf: &mut [u8]) -> Result<(), getrandom_v2::Error> {
        unsafe { random(buf.as_mut_ptr(), buf.len()) };
        Ok(())
    }
    getrandom_v2::register_custom_getrandom!(getrandom_v2_custom);

    // ---- tracing: forward events + span timings to the host ---------------------------------------

    struct HostLayer;

    struct StartTime(f64);

    impl<S> Layer<S> for HostLayer
    where
        S: Subscriber + for<'a> LookupSpan<'a>,
    {
        fn on_new_span(&self, _attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
            if let Some(span) = ctx.span(id) {
                span.extensions_mut().insert(StartTime(unsafe { now() }));
            }
        }

        fn on_close(&self, id: Id, ctx: Context<'_, S>) {
            if let Some(span) = ctx.span(&id) {
                let start = span.extensions().get::<StartTime>().map(|s| s.0);
                if let Some(start) = start {
                    let ms = unsafe { now() } - start;
                    // Machine-readable: the worker parses `span:<name>:<ms>` lines.
                    host_log(LOG_DEBUG, &format!("span:{}:{:.1}", span.name(), ms));
                }
            }
        }

        fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
            struct V(String);
            impl tracing::field::Visit for V {
                fn record_debug(&mut self, f: &tracing::field::Field, v: &dyn std::fmt::Debug) {
                    use std::fmt::Write;
                    if f.name() == "message" {
                        let _ = write!(self.0, "{v:?} ");
                    } else {
                        let _ = write!(self.0, "{}={v:?} ", f.name());
                    }
                }
                fn record_str(&mut self, f: &tracing::field::Field, v: &str) {
                    use std::fmt::Write;
                    if f.name() == "message" {
                        let _ = write!(self.0, "{v} ");
                    } else {
                        let _ = write!(self.0, "{}={v} ", f.name());
                    }
                }
            }
            let mut v = V(String::new());
            event.record(&mut v);
            let level = match *event.metadata().level() {
                tracing::Level::ERROR => LOG_ERROR,
                tracing::Level::WARN => LOG_WARN,
                tracing::Level::INFO => LOG_INFO,
                _ => LOG_DEBUG,
            };
            host_log(level, v.0.trim_end());
        }
    }

    fn init_once() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            panic::set_hook(Box::new(|info| {
                host_log(LOG_ERROR, &format!("panic: {info}"));
            }));
            let _ = tracing_subscriber::registry().with(HostLayer).try_init();
        });
    }

    // ---- ABI ---------------------------------------------------------------------------------------

    #[repr(C)]
    pub struct ResultHeader {
        status: u64,
        info_ptr: u64,
        info_len: u64,
        data_ptr: u64,
        data_len: u64,
    }

    fn leak_bytes(v: Vec<u8>) -> (u64, u64) {
        let len = v.len() as u64;
        // Keep exact-capacity boxed slices so `free_result` can rebuild the Vec.
        let boxed: Box<[u8]> = v.into_boxed_slice();
        (Box::into_raw(boxed) as *mut u8 as u64, len)
    }

    fn make_result(status: u64, info: String, data: Vec<u8>) -> usize {
        let (info_ptr, info_len) = leak_bytes(info.into_bytes());
        let (data_ptr, data_len) = leak_bytes(data);
        let hdr = Box::new(ResultHeader { status, info_ptr, info_len, data_ptr, data_len });
        Box::into_raw(hdr) as usize
    }

    fn ok(info: impl serde::Serialize, data: Vec<u8>) -> usize {
        make_result(0, serde_json::to_string(&info).unwrap_or_default(), data)
    }

    fn err(e: anyhow::Error) -> usize {
        let msg = format!("{e:#}");
        host_log(LOG_ERROR, &msg);
        make_result(1, serde_json::json!({ "error": msg }).to_string(), Vec::new())
    }

    unsafe fn slice<'a>(ptr: usize, len: usize) -> &'a [u8] {
        if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(ptr as *const u8, len) }
        }
    }

    unsafe fn str_arg<'a>(ptr: usize, len: usize) -> anyhow::Result<&'a str> {
        std::str::from_utf8(unsafe { slice(ptr, len) }).map_err(|e| anyhow::anyhow!("utf-8: {e}"))
    }

    /// Initializes the panic hook and the tracing forwarder. Idempotent; called by every export.
    #[unsafe(no_mangle)]
    pub extern "C" fn init() {
        init_once();
    }

    // ---- thread pool -------------------------------------------------------------------------------

    /// Builds rayon's global pool with `n_threads` worker threads and returns the number of threads
    /// the pool ended up with (`0` = the pool could not be built, e.g. it was already initialized).
    ///
    /// Single-threaded build: always returns 1 and does nothing (rayon falls back to running work
    /// on the calling thread).
    ///
    /// Must be called **before** any proving work, from the thread that owns the module, and only
    /// once. Each worker costs `stack_size` bytes of linear memory (16 MiB by default, allocated by
    /// the host through [`alloc`]) plus its TLS block; that memory is never released — the pool
    /// lives as long as the instance.
    #[cfg(target_feature = "atomics")]
    #[unsafe(no_mangle)]
    pub extern "C" fn init_thread_pool(n_threads: usize) -> usize {
        init_once();
        if n_threads <= 1 {
            return 1;
        }
        let built = rayon::ThreadPoolBuilder::new()
            .num_threads(n_threads)
            .spawn_handler(|thread| {
                // The closure is handed to the host as a raw pointer and reclaimed by
                // `worker_entry` on the Worker's thread.
                let boxed: Box<Box<dyn FnOnce() + Send>> = Box::new(Box::new(move || thread.run()));
                unsafe { spawn_thread(Box::into_raw(boxed) as *mut u8 as usize) };
                Ok(())
            })
            .build_global();
        match built {
            Ok(()) => rayon::current_num_threads(),
            Err(e) => {
                host_log(LOG_ERROR, &format!("init_thread_pool({n_threads}) failed: {e}"));
                0
            }
        }
    }

    /// Single-threaded build: no pool to build.
    #[cfg(not(target_feature = "atomics"))]
    #[unsafe(no_mangle)]
    pub extern "C" fn init_thread_pool(_n_threads: usize) -> usize {
        init_once();
        1
    }

    /// Entry point of a spawned Worker: runs the rayon thread body handed to `host.spawn_thread`.
    /// The Worker must have set `__stack_pointer` and called `__wasm_init_tls` **before** this.
    #[cfg(target_feature = "atomics")]
    #[unsafe(no_mangle)]
    pub extern "C" fn worker_entry(ptr: usize) {
        let boxed: Box<Box<dyn FnOnce() + Send>> =
            unsafe { Box::from_raw(ptr as *mut Box<dyn FnOnce() + Send>) };
        boxed();
    }

    /// Number of threads rayon will use for the next parallel section.
    #[unsafe(no_mangle)]
    pub extern "C" fn thread_count() -> usize {
        rayon::current_num_threads()
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn alloc(len: usize) -> usize {
        init_once();
        if len == 0 {
            return 8;
        }
        let layout = Layout::from_size_align(len, 8).expect("layout");
        let p = unsafe { sys_alloc(layout) };
        assert!(!p.is_null(), "alloc({len}) failed");
        p as usize
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn dealloc(ptr: usize, len: usize) {
        if ptr == 0 || len == 0 {
            return;
        }
        let layout = Layout::from_size_align(len, 8).expect("layout");
        unsafe { sys_dealloc(ptr as *mut u8, layout) }
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn free_result(ptr: usize) {
        if ptr == 0 {
            return;
        }
        unsafe {
            let hdr = Box::from_raw(ptr as *mut ResultHeader);
            for (p, l) in [(hdr.info_ptr, hdr.info_len), (hdr.data_ptr, hdr.data_len)] {
                if l > 0 {
                    drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p as *mut u8, l as usize)));
                }
            }
        }
    }

    /// `execute(executable_json, args_json)` -> info = ExecutionStats, data = bincode(ProverInput).
    #[unsafe(no_mangle)]
    pub extern "C" fn execute(exe_ptr: usize, exe_len: usize, args_ptr: usize, args_len: usize) -> usize {
        init_once();
        let run = || -> anyhow::Result<(core::ExecutionStats, Vec<u8>)> {
            let exe = unsafe { str_arg(exe_ptr, exe_len)? };
            let args = unsafe { str_arg(args_ptr, args_len)? };
            let (input, mut stats) = core::execute(exe, args)?;
            let bytes = core::prover_input_to_bytes(&input)?;
            stats.prover_input_bytes = bytes.len();
            Ok((stats, bytes))
        };
        match run() {
            Ok((stats, bytes)) => ok(stats, bytes),
            Err(e) => err(e),
        }
    }

    /// `prove(prover_input_bytes, params_json)` -> info = ProofStats, data = bincode(CairoProof).
    #[unsafe(no_mangle)]
    pub extern "C" fn prove(in_ptr: usize, in_len: usize, params_ptr: usize, params_len: usize) -> usize {
        init_once();
        let run = || -> anyhow::Result<(Vec<u8>, core::ProofStats)> {
            let params = core::parse_params(unsafe { str_arg(params_ptr, params_len)? })?;
            let input = core::prover_input_from_bytes(unsafe { slice(in_ptr, in_len) })?;
            core::prove(input, params)
        };
        match run() {
            Ok((bytes, stats)) => ok(stats, bytes),
            Err(e) => err(e),
        }
    }

    /// `resources(prover_input_bytes, params_json)` -> info = ResourceSummary (no trace is
    /// generated: the counters come from the adapter's `ExecutionResources`).
    #[unsafe(no_mangle)]
    pub extern "C" fn resources(in_ptr: usize, in_len: usize, params_ptr: usize, params_len: usize) -> usize {
        init_once();
        let run = || -> anyhow::Result<core::ResourceSummary> {
            let params = core::parse_params(unsafe { str_arg(params_ptr, params_len)? })?;
            let input = core::prover_input_from_bytes(unsafe { slice(in_ptr, in_len) })?;
            Ok(core::resources(&input, &params))
        };
        match run() {
            Ok(summary) => ok(summary, Vec::new()),
            Err(e) => err(e),
        }
    }

    /// `verify(proof_bytes, params_json)` -> status 0 and info = {"ok": true} if valid, else
    /// status 1 with the verification error.
    #[unsafe(no_mangle)]
    pub extern "C" fn verify(proof_ptr: usize, proof_len: usize, params_ptr: usize, params_len: usize) -> usize {
        init_once();
        let run = || -> anyhow::Result<bool> {
            let params = core::parse_params(unsafe { str_arg(params_ptr, params_len)? })?;
            core::verify(unsafe { slice(proof_ptr, proof_len) }, params)
        };
        match run() {
            Ok(valid) => ok(serde_json::json!({ "ok": valid }), Vec::new()),
            Err(e) => err(e),
        }
    }

    /// `proof_to_felts(proof_bytes, params_json)` -> data = JSON array of hex felts (cairo-serde).
    #[unsafe(no_mangle)]
    pub extern "C" fn proof_to_felts(proof_ptr: usize, proof_len: usize, params_ptr: usize, params_len: usize) -> usize {
        init_once();
        let run = || -> anyhow::Result<Vec<u8>> {
            let params = core::parse_params(unsafe { str_arg(params_ptr, params_len)? })?;
            let felts = core::proof_to_felts(unsafe { slice(proof_ptr, proof_len) }, params)?;
            Ok(serde_json::to_vec(&felts)?)
        };
        match run() {
            Ok(bytes) => ok(serde_json::json!({ "felts": bytes.len() }), bytes),
            Err(e) => err(e),
        }
    }

    /// Returns the default prover parameters JSON (data).
    #[unsafe(no_mangle)]
    pub extern "C" fn default_params() -> usize {
        init_once();
        ok(serde_json::json!({}), core::DEFAULT_PARAMS_JSON.as_bytes().to_vec())
    }
}
