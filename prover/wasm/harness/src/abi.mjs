// Runtime-agnostic (browser Worker / Node) binding for the hand-written wasm64 ABI of
// prover/wasm/src/lib.rs. Every pointer/length crosses the boundary as a BigInt (i64).
//
//   const mod = await ProverModule.instantiate(bytesOrResponse, { log, now });
//   const { info, data, ms, memoryBytes } = mod.call("execute", [exeJson, argsJson]);

const LOG_LEVELS = ["error", "warn", "info", "debug"];

export class ProverModule {
  /**
   * @param {WebAssembly.Instance} instance
   * @param {{ onLog?: (level: string, msg: string) => void }} opts
   */
  constructor(instance, opts = {}) {
    this.instance = instance;
    this.exports = instance.exports;
    this.memory = /** @type {WebAssembly.Memory} */ (instance.exports.memory);
    this.onLog = opts.onLog ?? (() => {});
    /** span timings collected from `span:<name>:<ms>` debug lines, per call */
    this.spans = [];
    this.lastPanic = null;
    this.exports.init();
  }

  /**
   * @param {BufferSource | Response | Promise<Response>} source
   * @param {{ onLog?: (level: string, msg: string) => void }} opts
   */
  static async instantiate(source, opts = {}) {
    let mod = null;
    const imports = {
      host: {
        log: (level, ptr, len) => mod?._hostLog(Number(level), ptr, len),
        random: (ptr, len) => mod?._hostRandom(ptr, len),
        now: () => performance.now(),
      },
    };
    const module =
      source instanceof Response || source instanceof Promise
        ? await WebAssembly.compileStreaming(source)
        : await WebAssembly.compile(source);
    // Some transitive crates (web-time, js-sys via getrandom/wasm-bindgen) link the wasm-bindgen
    // runtime glue (`__wbindgen_placeholder__::__wbindgen_throw`, externref table helpers, ...)
    // even though nothing on the prover's call path reaches it (no `__wbg_now_*` etc. is
    // imported, so the code is dead but the imports remain). Stub every import outside `host`
    // with a function that throws: if one is ever reached, the failure is loud.
    for (const imp of WebAssembly.Module.imports(module)) {
      if (imp.module === "host") continue;
      if (imp.kind !== "function") throw new Error(`unsupported non-function import ${imp.module}.${imp.name}`);
      (imports[imp.module] ??= {})[imp.name] = () => {
        throw new Error(`unexpected call into stubbed import ${imp.module}.${imp.name}`);
      };
    }
    const instance = await WebAssembly.instantiate(module, imports);
    mod = new ProverModule(instance, opts);
    return mod;
  }

  _u8(ptr, len) {
    return new Uint8Array(this.memory.buffer, Number(ptr), Number(len));
  }

  _hostLog(level, ptr, len) {
    const msg = new TextDecoder().decode(this._u8(ptr, len));
    const m = /^span:(.+):([\d.]+)$/.exec(msg);
    if (m) {
      this.spans.push({ name: m[1], ms: Number(m[2]) });
      return;
    }
    if (msg.startsWith("panic:")) this.lastPanic = msg;
    this.onLog(LOG_LEVELS[level] ?? "debug", msg);
  }

  _hostRandom(ptr, len) {
    // crypto.getRandomValues caps at 65536 bytes per call.
    const view = this._u8(ptr, len);
    for (let off = 0; off < view.length; off += 65536) {
      crypto.getRandomValues(view.subarray(off, Math.min(off + 65536, view.length)));
    }
  }

  /** Copies `bytes` into wasm memory; returns [ptr, len] BigInts. */
  _push(bytes) {
    const len = BigInt(bytes.byteLength);
    if (bytes.byteLength === 0) return [0n, 0n];
    const ptr = this.exports.alloc(len);
    this._u8(ptr, len).set(bytes);
    return [ptr, len];
  }

  _pop(ptr, len) {
    if (len !== 0n) this.exports.dealloc(ptr, len);
  }

  get memoryBytes() {
    return this.memory.buffer.byteLength;
  }

  /**
   * Calls an export taking (ptr,len) pairs and returning a ResultHeader pointer.
   * @param {string} fn
   * @param {(string | Uint8Array)[]} args
   * @returns {{ info: any, data: Uint8Array, ms: number, memoryBytes: number, spans: {name:string, ms:number}[] }}
   */
  call(fn, args) {
    const enc = new TextEncoder();
    const pushed = args.map((a) => this._push(typeof a === "string" ? enc.encode(a) : a));
    const flat = pushed.flat();
    this.spans = [];
    this.lastPanic = null;
    const t0 = performance.now();
    let hdr;
    try {
      hdr = this.exports[fn](...flat);
    } catch (e) {
      const panic = this.lastPanic ? ` (${this.lastPanic})` : "";
      throw new Error(`${fn} trapped: ${e?.message ?? e}${panic}`);
    }
    const ms = performance.now() - t0;
    for (const [p, l] of pushed) this._pop(p, l);
    const dv = new DataView(this.memory.buffer);
    const h = Number(hdr);
    const status = dv.getBigUint64(h, true);
    const infoPtr = dv.getBigUint64(h + 8, true);
    const infoLen = dv.getBigUint64(h + 16, true);
    const dataPtr = dv.getBigUint64(h + 24, true);
    const dataLen = dv.getBigUint64(h + 32, true);
    const infoStr = new TextDecoder().decode(this._u8(infoPtr, infoLen));
    const data = this._u8(dataPtr, dataLen).slice(); // copy out of wasm memory
    this.exports.free_result(hdr);
    let info;
    try {
      info = JSON.parse(infoStr);
    } catch {
      info = { raw: infoStr };
    }
    if (status !== 0n) {
      throw new Error(`${fn} failed: ${info.error ?? infoStr}`);
    }
    return { info, data, ms, memoryBytes: this.memoryBytes, spans: this.spans };
  }
}
