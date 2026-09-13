// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Hellproof contributors
//! Bounded diagnostic only: compare pinned SIMD kernels to scalar field/CPU kernels.
use stwo::core::circle::SECURE_FIELD_CIRCLE_GEN;
use stwo::core::fields::batch_inverse;
use stwo::core::fields::cm31::CM31;
use stwo::core::fields::m31::M31;
use stwo::core::fields::qm31::QM31;
use stwo::core::pcs::TreeVec;
use stwo::core::pcs::quotients::PointSample;
use stwo::core::poly::circle::CanonicCoset;
use stwo::prover::backend::CpuBackend;
use stwo::prover::backend::simd::SimdBackend;
use stwo::prover::backend::simd::cm31::PackedCM31;
use stwo::prover::backend::simd::column::BaseColumn;
use stwo::prover::backend::simd::qm31::PackedQM31;
use stwo::prover::pcs::quotient_ops::compute_fri_quotients;
use stwo::prover::poly::BitReversedOrder;
use stwo::prover::poly::circle::{CircleCoefficients, CircleEvaluation, PolyOps};

fn value(i: usize, seed: u64) -> M31 {
    let x = (i as u64)
        .wrapping_add(seed)
        .wrapping_mul(0x9e3779b97f4a7c15);
    M31::reduce(x ^ (x >> 31))
}
fn secure(i: usize) -> QM31 {
    QM31::from_m31_array(std::array::from_fn(|j| value(i * 4 + j, 13)))
}

/// Vary extension inversion sizes across SIMD and scratch boundaries; verify every lane.
#[unsafe(no_mangle)]
pub extern "C" fn inverses(n: u32) -> u32 {
    let n = n as usize;
    let cm: Vec<_> = (0..n)
        .map(|i| {
            PackedCM31::from_array(std::array::from_fn(|j| {
                CM31(value(i * 16 + j, 3), value(i * 16 + j, 7))
            }))
        })
        .collect();
    let qm: Vec<_> = (0..n)
        .map(|i| PackedQM31::from_array(std::array::from_fn(|j| secure(i * 16 + j))))
        .collect();
    for (src, inv) in cm.iter().zip(batch_inverse(&cm)) {
        for (a, b) in src.to_array().into_iter().zip(inv.to_array()) {
            if a * b != CM31::from(M31::from(1u32)) {
                return 1;
            }
        }
    }
    for (src, inv) in qm.iter().zip(batch_inverse(&qm)) {
        for (a, b) in src.to_array().into_iter().zip(inv.to_array()) {
            if a * b != QM31::from(1u32) {
                return 2;
            }
        }
    }
    0
}

/// Exercise iFFT, LDE and barycentric interpolation on fully specified evaluations.
#[unsafe(no_mangle)]
pub extern "C" fn roundtrip(log: u32, seed: u32) -> u32 {
    let domain = CanonicCoset::new(log).circle_domain();
    let values: Vec<_> = (0..domain.size()).map(|i| value(i, seed as u64)).collect();
    let eval = CircleEvaluation::<SimdBackend, M31, BitReversedOrder>::new(
        domain,
        BaseColumn::from_cpu(&values),
    );
    if eval.values.as_slice() != values.as_slice() {
        return 10;
    }
    let cloned = eval.clone();
    if cloned.values.as_slice() != values.as_slice() {
        return 11;
    }
    let tw =
        SimdBackend::precompute_twiddles(CanonicCoset::new(log + 1).circle_domain().half_coset);
    let poly = cloned.interpolate_with_twiddles(&tw);
    let back = poly.evaluate_with_twiddles(domain, &tw);
    if back.values.as_slice() != values.as_slice() {
        let mut found = false;
        for i in 0..values.len() {
            if std::hint::black_box(back.values.as_slice()[i]) != std::hint::black_box(values[i]) {
                unsafe {
                    DETAIL = [
                        1,
                        i as u64,
                        values[i].0 as u64,
                        back.values.as_slice()[i].0 as u64,
                        values.as_ptr() as u64,
                        back.values.data.as_ptr() as u64,
                        poly.coeffs.data.as_ptr() as u64,
                        tw.twiddles.as_ptr() as u64,
                    ];
                }
                found = true;
                break;
            }
        }
        return if found { 1 } else { 12 };
    }
    let big = poly.evaluate_with_twiddles(CanonicCoset::new(log + 1).circle_domain(), &tw);
    let backpoly = big.interpolate_with_twiddles(&tw);
    let point = SECURE_FIELD_CIRCLE_GEN.mul(123456789u128);
    if poly.eval_at_point(point) != backpoly.eval_at_point(point) {
        return 2;
    }
    let weights = CircleEvaluation::<SimdBackend, M31, BitReversedOrder>::barycentric_weights(
        CanonicCoset::new(log),
        point,
    );
    if SimdBackend::barycentric_eval_at_point(&eval, &weights) != poly.eval_at_point(point) {
        return 3;
    }
    0
}

/// Identical mixed-height columns and samples, scalar and SIMD quotient pipeline.
#[unsafe(no_mangle)]
pub extern "C" fn quotients(log: u32, seed: u32) -> u32 {
    let domain = CanonicCoset::new(log).circle_domain();
    let cpu_tw = CpuBackend::precompute_twiddles(domain.half_coset);
    let simd_tw = SimdBackend::precompute_twiddles(domain.half_coset);
    let point = SECURE_FIELD_CIRCLE_GEN.mul(123456789u128);
    let points = [point, point.double()];
    let heights = [
        4,
        8,
        14.min(log - 1),
        15.min(log - 1),
        17.min(log - 1),
        18.min(log - 1),
        log,
    ];
    let mut cpu_cols = vec![];
    let mut simd_cols = vec![];
    let mut samples = vec![];
    for (i, height) in heights.into_iter().enumerate() {
        let poly = CircleCoefficients::<CpuBackend>::new(
            (0..8).map(|j| value(j + i * 8, seed as u64)).collect(),
        );
        let small_domain = CanonicCoset::new(height).circle_domain();
        let cpu = poly.evaluate(small_domain);
        let simd = CircleEvaluation::<SimdBackend, M31, BitReversedOrder>::new(
            small_domain,
            BaseColumn::from_cpu(&cpu.values),
        );
        // Samples include each column's projection from the lifting domain.
        samples.push(
            points
                .iter()
                .map(|p| PointSample {
                    point: *p,
                    value: poly.eval_at_point(p.repeated_double(log - height)),
                })
                .collect::<Vec<_>>(),
        );
        cpu_cols.push(cpu);
        simd_cols.push(simd);
    }
    let samples = TreeVec(vec![samples]);
    let random = secure(seed as usize);
    let a = compute_fri_quotients(
        &TreeVec(vec![cpu_cols.iter().collect()]),
        &samples,
        random,
        log,
        &cpu_tw,
        1,
    );
    let b = compute_fri_quotients(
        &TreeVec(vec![simd_cols.iter().collect()]),
        &samples,
        random,
        log,
        &simd_tw,
        1,
    )
    .to_cpu();
    if a.values.columns != b.values.columns {
        return 1;
    }
    0
}

/// Keep an allocation alive so subsequent kernels exercise Memory64 addresses above 4/8 GiB.
/// Diagnostic instance is discarded after one campaign; no handle escapes the WASM module.
#[unsafe(no_mangle)]
pub extern "C" fn reserve_address_space(bytes: u64) -> u64 {
    let layout = std::alloc::Layout::from_size_align(bytes as usize, 64).unwrap();
    let ptr = unsafe { std::alloc::alloc(layout) };
    assert!(!ptr.is_null());
    unsafe {
        ptr.write(0x5a);
        ptr.add(bytes as usize - 1).write(0xa5);
    }
    ptr as u64
}

static mut DETAIL: [u64; 8] = [0; 8];
#[unsafe(no_mangle)]
pub extern "C" fn detail(i: u32) -> u64 {
    unsafe { DETAIL[i as usize] }
}
