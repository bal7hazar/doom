// SPDX-License-Identifier: GPL-2.0-only
/** Flat Cairo ABI for doom_run. Felts are canonical hex strings; no lossy Number conversion. */
const PRIME = (1n << 251n) + 17n * (1n << 192n) + 1n;
const MAX_TIC = 0x40000000;
function felt(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new RangeError('unsafe felt number');
  const n = BigInt(value);
  if (n < 0n || n >= PRIME) throw new RangeError('noncanonical felt');
  return `0x${n.toString(16)}`;
}
function bounded(value, max, label) {
  const n = BigInt(felt(value));
  if (n > BigInt(max)) throw new RangeError(label);
  return Number(n);
}
function array(values) { return [felt(values.length), ...values.map(felt)]; }
function words(values) { return values.map(v => felt(bounded(v, 0xffffffff, 'ticcmd word'))); }
export function encodeGenesis(level = 0) { return [felt(bounded(level, 0xffffffff, 'level'))]; }
export function encodeStep(state, commands) { return [...array(state), ...array(words(commands))]; }
export function encodeSegment(state, commands, ticStart, maxTics = commands.length) {
  return [...encodeStep(state, commands), felt(bounded(ticStart, MAX_TIC, 'tic_start')),
    felt(bounded(maxTics, MAX_TIC, 'max_tics'))];
}
function reader(output) {
  const values = output.map(felt);
  let offset = 0;
  return {
    next() { if (offset === values.length) throw new RangeError('truncated output'); return values[offset++]; },
    array() {
      const count = bounded(this.next(), values.length, 'array length');
      if (count > values.length - offset) throw new RangeError('truncated array');
      const result = values.slice(offset, offset + count); offset += count; return result;
    },
    end() { if (offset !== values.length) throw new RangeError('trailing output'); },
  };
}
export function decodeGenesis(output) {
  const r = reader(output), state = r.array(), hash = r.next(); r.end();
  return { state, hash };
}
export function decodeStep(output) {
  const r = reader(output), status = bounded(r.next(), 3, 'status');
  const state = r.array(), snapshot = r.array(); r.end();
  return { status, state, snapshot };
}
export function decodeSegment(output) {
  const r = reader(output), version = bounded(r.next(), 1, 'version');
  if (version !== 1) throw new RangeError('version');
  const hIn = r.next(), hOut = r.next();
  const ticStart = bounded(r.next(), MAX_TIC, 'tic_start'), ticEnd = bounded(r.next(), MAX_TIC, 'tic_end');
  const status = bounded(r.next(), 3, 'status'), inputsCommitment = r.next();
  const kills = bounded(r.next(), 0xffffffff, 'kills'), items = bounded(r.next(), 0xffffffff, 'items');
  const secrets = bounded(r.next(), 0xffffffff, 'secrets'); r.end();
  if (ticEnd < ticStart) throw new RangeError('reversed tics');
  return { version, hIn, hOut, ticStart, ticEnd, status, inputsCommitment, kills, items, secrets };
}
