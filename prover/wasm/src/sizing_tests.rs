// SPDX-License-Identifier: Apache-2.0
use super::*;
use std::collections::HashMap;
use stwo_cairo_adapter::{ExecutionResources, MemoryTablesSizes};

fn empty() -> ExecutionResources {
    ExecutionResources {
        opcodes_instance_counter: HashMap::new(),
        builtin_instance_counter: HashMap::new(),
        memory_tables_sizes: MemoryTablesSizes {
            memory_address_to_id: 17,
            memory_id_to_big: 1,
            memory_id_to_small: 1,
        },
        verify_instruction: 1,
        unique_aggregator_inputs: HashMap::new(),
    }
}

fn opcode(name: &str, n: usize) -> ResourceSummary {
    let mut r = empty();
    r.opcodes_instance_counter.insert(name.into(), n);
    summarize_resources(r, &default_params())
}

fn with_builtin(name: &str, instances: usize, unique: usize) -> ExecutionResources {
    let mut r = empty();
    r.builtin_instance_counter.insert(name.into(), instances);
    r.unique_aggregator_inputs.insert(name.into(), unique);
    r
}

fn auxiliary(summary: &ResourceSummary, name: &str) -> usize {
    summary
        .auxiliary_components
        .iter()
        .find(|(key, _)| key == name)
        .unwrap()
        .1
}

#[test]
fn real_blake_claim_heights_match_and_log20_registry_rejects() {
    let r: ExecutionResources =
        serde_json::from_str(include_str!("../tests/fixtures/real-blake-resources.json")).unwrap();
    let s = summarize_resources(r, &default_params());
    let expected: serde_json::Value = serde_json::from_str(include_str!(
        "../tests/fixtures/real-blake-claim-heights.json"
    ))
    .unwrap();
    let mut counts: HashMap<String, usize> = s.opcodes.iter().cloned().collect();
    for (key, count) in &s.builtins {
        if key != "output_builtin" {
            counts.insert(
                if key == "pedersen_builtin" {
                    "pedersen_builtin_narrow_windows".into()
                } else {
                    key.clone()
                },
                *count,
            );
        }
    }
    counts.extend(s.auxiliary_components.iter().cloned());
    counts.insert(
        "memory_address_to_id".into(),
        (s.memory_address_to_id - 1).div_ceil(16),
    );
    counts.insert("memory_id_to_big".into(), s.memory_id_to_big);
    counts.insert("memory_id_to_small".into(), s.memory_id_to_small);
    counts.insert("verify_instruction".into(), s.verify_instruction);
    let logs = expected["component_log_sizes"].as_object().unwrap();
    assert_eq!(
        counts.len(),
        logs.len(),
        "every variable component in the real claim is covered"
    );
    for (name, expected) in logs {
        assert_eq!(
            log2_ceil(component_rows(counts[name])),
            expected.as_u64().unwrap() as u32,
            "{name}"
        );
    }
    assert_eq!(auxiliary(&s, "blake_g"), 1_303_200);
    assert_eq!(s.max_component, "blake_g");
    assert_eq!(s.max_component_rows, 1 << 21);
    assert_eq!(s.log_max_component_size, 21);
    assert_eq!(s.estimated_trace_log_size, 21);
    assert!(!s.fits_leaf_registry);
    assert_eq!(s.max_sequence_log_size, 20);
    assert!(
        s.fits_preprocessed_trace,
        "Blake G log21 does not require Seq21"
    );
}

#[test]
fn real_poseidon_baseline_expands_padded_aggregator_not_raw_unique_inputs() {
    let r: ExecutionResources = serde_json::from_str(include_str!(
        "../tests/fixtures/real-poseidon-resources.json"
    ))
    .unwrap();
    let s = summarize_resources(r, &default_params());
    assert_eq!(auxiliary(&s, "poseidon_aggregator"), 65_136);
    assert_eq!(
        auxiliary(&s, "poseidon_3_partial_rounds_chain"),
        27 * 65_536
    );
    assert_eq!(auxiliary(&s, "poseidon_full_round_chain"), 8 * 65_536);
    assert_eq!(auxiliary(&s, "cube_252"), 107 * 65_536);
    assert_eq!(auxiliary(&s, "range_check_252_width_27"), 83 * 65_536);
    assert_eq!(s.max_component, "cube_252");
    assert_eq!(s.max_component_rows, 1 << 23);
    assert!(!s.fits_leaf_registry);
    assert!(s.fits_preprocessed_trace);
}

#[test]
fn blake_uses_active_rows_and_crosses_the_exact_log20_boundary() {
    for n in [1, 15, 16, 17, 8_193, 13_107, 13_108] {
        let s = opcode("blake_compress_opcode", n);
        assert_eq!(auxiliary(&s, "blake_round"), 10 * n);
        assert_eq!(auxiliary(&s, "blake_g"), 80 * n);
        assert_eq!(auxiliary(&s, "triple_xor_32"), 8 * n);
        assert_eq!(s.max_component_rows, component_rows(80 * n));
        assert_eq!(s.fits_leaf_registry, n <= 13_107);
    }
}

#[test]
fn poseidon_padding_thresholds_and_no_intermediate_round_padding() {
    for unique in [1, 15, 16, 17, 4_095, 4_096, 4_097, 8_191, 8_192, 8_193] {
        let s = summarize_resources(
            with_builtin("poseidon_builtin", 16_384, unique),
            &default_params(),
        );
        let a = component_rows(unique);
        assert_eq!(auxiliary(&s, "poseidon_aggregator"), unique);
        assert_eq!(auxiliary(&s, "cube_252"), 107 * a);
        assert_eq!(s.fits_leaf_registry, unique <= 8_192);
    }
}

#[test]
fn other_variable_auxiliaries_are_sized() {
    for (unique, fits) in [(16_384, true), (16_385, false)] {
        let s = summarize_resources(
            with_builtin("pedersen_builtin", 32_768, unique),
            &default_params(),
        );
        assert_eq!(
            auxiliary(&s, "partial_ec_mul_window_bits_9"),
            56 * component_rows(unique)
        );
        assert_eq!(s.fits_leaf_registry, fits);
    }
    for (instances, fits) in [(4_096, true), (8_192, false)] {
        let s = summarize_resources(
            with_builtin("ec_op_builtin", instances, 0),
            &default_params(),
        );
        assert_eq!(auxiliary(&s, "partial_ec_mul_generic"), 252 * instances);
        assert_eq!(s.fits_leaf_registry, fits);
    }
}

#[test]
fn fixed_tables_sequences_and_registry_height_are_different_limits() {
    let mut params = default_params();
    let small = summarize_resources(empty(), &params);
    assert_eq!(small.log_max_component_size, 4);
    assert_eq!(small.fixed_component_log_size, 20);
    assert_eq!(small.max_sequence_log_size, 20);
    assert_eq!(small.estimated_trace_log_size, 20);
    assert!(small.fits_leaf_registry);
    let g21 = opcode("blake_compress_opcode", 13_108);
    assert_eq!(g21.log_max_component_size, 21);
    assert_eq!(g21.max_sequence_log_size, 20);
    assert!(g21.fits_preprocessed_trace);
    let mut r = empty();
    r.memory_tables_sizes.memory_id_to_small = (1 << 20) + 1;
    assert!(!summarize_resources(r, &params).fits_preprocessed_trace);
    params.preprocessed_trace = PreProcessedTraceVariant::Canonical;
    let wide = summarize_resources(with_builtin("pedersen_builtin", 16, 1), &params);
    assert_eq!(auxiliary(&wide, "partial_ec_mul_window_bits_18"), 28 * 16);
    assert_eq!(wide.fixed_component_log_size, 23);
    assert_eq!(wide.max_sequence_log_size, 23);
    assert_eq!(wide.estimated_trace_log_size, 25);
    assert!(!wide.fits_leaf_registry);
    params.preprocessed_trace = PreProcessedTraceVariant::CanonicalWithoutPedersen;
    assert!(
        !summarize_resources(with_builtin("pedersen_builtin", 16, 1), &params)
            .fits_preprocessed_trace
    );
}

#[test]
fn lifting_policy_is_checked_without_changing_parameters() {
    let mut p = default_params();
    for (size, fits) in [(20, false), (21, true), (22, false)] {
        p.lifting_size_policy = LiftingSizePolicy::Fixed(size);
        assert_eq!(summarize_resources(empty(), &p).fits_leaf_registry, fits);
    }
    p.lifting_size_policy = LiftingSizePolicy::Auto;
    assert!(summarize_resources(empty(), &p).fits_leaf_registry);
}

#[test]
fn address_zero_padding_and_big_table_split_boundaries() {
    for (len, expected) in [(16 * 1024, 10), (16 * 1024 + 1, 10), (16 * 1024 + 2, 11)] {
        let mut r = empty();
        r.memory_tables_sizes.memory_address_to_id = len;
        assert_eq!(
            summarize_resources(r, &default_params()).log_max_component_size,
            expected
        );
    }
    for (len, parts, fits) in [
        (1 << 20, 1, true),
        ((1 << 20) + 1, 2, true),
        (16 << 20, 16, true),
        ((16 << 20) + 1, 17, false),
    ] {
        let mut r = empty();
        r.memory_tables_sizes.memory_id_to_big = len;
        let s = summarize_resources(r, &default_params());
        assert_eq!(s.n_memory_id_to_big_components, parts);
        assert_eq!(s.fits_leaf_registry, fits);
    }
}

#[test]
fn equal_padded_heights_name_the_larger_raw_component() {
    let mut r = empty();
    r.opcodes_instance_counter
        .insert("blake_compress_opcode".into(), 10_000);
    r.opcodes_instance_counter
        .insert("add_opcode".into(), 900_000);
    let s = summarize_resources(r, &default_params());
    assert_eq!(s.max_component_rows, 1 << 20);
    assert_eq!(auxiliary(&s, "blake_g"), 800_000);
    assert_eq!(s.max_component, "add_opcode");
}

#[test]
fn no_auxiliary_for_absent_builtins_and_no_wrap_on_oversize_counts() {
    let s = summarize_resources(empty(), &default_params());
    assert!(s.auxiliary_components.is_empty());
    let s = opcode("blake_compress_opcode", usize::MAX);
    assert!(!s.fits_leaf_registry);
    assert_eq!(s.log_max_component_size, usize::BITS);
}

#[test]
#[ignore = "build steps_k and set HELLPROOF_SIZING_EXECUTABLE; executes VM only, no proof"]
fn execute_original_microprograms() {
    let path = std::env::var("HELLPROOF_SIZING_EXECUTABLE").unwrap();
    let executable = std::fs::read_to_string(path).unwrap();
    for n in [1_032, 94_867] {
        let (input, stats) = execute(&executable, &format!("[{n}]")).unwrap();
        let summary = resources(&input, &default_params());
        assert!(summary.fits_leaf_registry);
        assert!(summary.fits_preprocessed_trace);
        assert_eq!(summary.n_steps + 1, stats.n_steps);
        assert!(!summary.auxiliary_components.is_empty());
    }
}
