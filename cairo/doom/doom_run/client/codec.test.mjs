// SPDX-License-Identifier: GPL-2.0-only
import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeGenesis, encodeStep, encodeSegment, decodeGenesis, decodeStep, decodeSegment } from './codec.mjs';

test('ABI length words are explicit and state is passed rather than its hash', () => {
  assert.deepEqual(encodeGenesis(), ['0x0']);
  assert.deepEqual(encodeStep([123, 456], [0x808080]), ['0x2', '0x7b', '0x1c8', '0x1', '0x808080']);
  assert.deepEqual(encodeSegment([123], [42], 9, 1), ['0x1', '0x7b', '0x1', '0x2a', '0x9', '0x1']);
});
test('decode preserves arbitrary felt precision and terminal status', () => {
  const hash = '0x7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00';
  assert.deepEqual(decodeGenesis([2, 1, 2, hash]), { state: ['0x1', '0x2'], hash });
  assert.deepEqual(decodeStep([3, 0, 0]), { status: 3, state: [], snapshot: [] });
  const result = decodeSegment([1, hash, hash, 1, 2, 0, hash, 3, 4, 5]);
  assert.equal(result.hIn, hash); assert.equal(result.kills, 3);
});
test('reject malformed envelopes and unsafe numbers', () => {
  for (const output of [[0], [0, 0, 1], [0, 0, 0, 99], [4, 0, 0]]) assert.throws(() => decodeStep(output));
  assert.throws(() => decodeGenesis([0]));
  assert.throws(() => decodeSegment([1, 0, 0, 2, 1, 0, 0, 0, 0, 0]));
  assert.throws(() => encodeStep([Number.MAX_SAFE_INTEGER + 1], []));
  assert.throws(() => encodeStep([], [0x100000000]));
  assert.throws(() => encodeStep([-1], []));
});
