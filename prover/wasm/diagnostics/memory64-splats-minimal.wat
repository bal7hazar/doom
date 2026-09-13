;; SPDX-License-Identifier: Apache-2.0
;; Copyright (c) 2026 Hellproof contributors
(module
 (memory (export "memory") i64 1 262144)
 (func (export "grow") (param i64) (result i64) (memory.grow (local.get 0)))
 (func (export "write") (param i64 i32) (i32.store (local.get 0) (local.get 1)))
 (func (export "scalar") (param i64) (result i32) (i32.load (local.get 0)))
 (func (export "splat") (param i64) (result i32) (i32x4.extract_lane 0 (v128.load32_splat (local.get 0))))
 (func (export "vector") (param i64) (result i32) (i32x4.extract_lane 0 (v128.load (local.get 0))))
)
