// SPDX-License-Identifier: Apache-2.0
//! The deployed router driven end-to-end over the S4 fixture with the 5-transaction plan of
//! `tools/emit_calldata.py` (packed payloads, state echoes), then the sequencing / binding
//! rejections: proof-id reuse, wrong phase, tampered echo, foreign caller.
use doom_contracts::router::{
    Checkpoint, IStwoCircuitRouterDispatcher, IStwoCircuitRouterDispatcherTrait, TAG_DONE,
    TAG_FRI, TAG_MERKLE, compute_fact,
};
use snforge_std::fs::{FileTrait, read_txt};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address, test_address,
};
use starknet::ContractAddress;
use stwo_circuit_phases::pack::pack;
use stwo_circuit_phases::sections::{Sections, fri_chunk, split};

const PROOF_ID: felt252 = 0x1;

/// `spikes/s4/results/N4_doom/verifier_output.json`.
fn n4_output_hash() -> [u32; 8] {
    [3123785184, 3718676270, 1469581383, 660429404, 3277334853, 1494218902, 3817731027, 3170188775]
}

/// The multiverifier circuit hash of the `doom` registry (docs/spikes/S4.md).
fn multiverifier_circuit_hash() -> [u32; 8] {
    [
        0xa5989715, 0x2377c07a, 0xc6d1e844, 0x54f0a04d, 0x8be65a7d, 0xfd73c261, 0x9078e728,
        0x973f680f,
    ]
}

fn sections() -> Sections {
    let file = FileTrait::new("../../fixtures/n4_root_proof.txt");
    let values = read_txt(@file);
    assert!(values.len() == 96033, "fixture length");
    split(values.span())
}

fn deploy_router() -> IStwoCircuitRouterDispatcher {
    let begin = declare("StwoPhasesBegin").unwrap().contract_class().class_hash;
    let merkle = declare("StwoPhasesMerkle").unwrap().contract_class().class_hash;
    let fri = declare("StwoPhasesFri").unwrap().contract_class().class_hash;
    let router = declare("StwoCircuitRouter").unwrap().contract_class();
    let (address, _) = router
        .deploy(@array![(*begin).into(), (*merkle).into(), (*fri).into()])
        .unwrap();
    IStwoCircuitRouterDispatcher { contract_address: address }
}

/// `(payload, lens)` of consecutive sections.
fn payload(sections: Span<Span<felt252>>) -> (Span<felt252>, Span<u32>) {
    let mut flat = array![];
    let mut lens = array![];
    for s in sections {
        flat.append_span(*s);
        lens.append((*s).len());
    }
    (pack(flat.span()).span(), lens.span())
}

#[derive(Drop)]
struct Plan {
    begin_payload: Span<felt252>,
    begin_lens: Span<u32>,
    merkle_payload: Span<felt252>,
    merkle_lens: Span<u32>,
    answers_payload: Span<felt252>,
    answers_lens: Span<u32>,
    fri1_payload: Span<felt252>,
    fri1_n: u32,
    fri2_payload: Span<felt252>,
    fri2_n: u32,
}

fn plan(sec: @Sections) -> Plan {
    let (begin_payload, begin_lens) = payload(
        array![
            sec.head.span(), sec.queried_values.at(0).span(), sec.decommitments.at(0).span(),
            sec.queried_values.at(1).span(), sec.decommitments.at(1).span(),
        ]
            .span(),
    );
    let (merkle_payload, merkle_lens) = payload(
        array![
            sec.queried_values.at(2).span(), sec.decommitments.at(2).span(),
            sec.queried_values.at(3).span(), sec.decommitments.at(3).span(),
        ]
            .span(),
    );
    let (answers_payload, answers_lens) = payload(
        array![
            sec.sampled_values.span(), sec.queried_values.at(0).span(),
            sec.queried_values.at(1).span(), sec.queried_values.at(2).span(),
            sec.queried_values.at(3).span(),
        ]
            .span(),
    );
    let fri1 = fri_chunk(sec.fri_layers, 0, 2);
    let fri2 = fri_chunk(sec.fri_layers, 2, 6);
    Plan {
        begin_payload,
        begin_lens,
        merkle_payload,
        merkle_lens,
        answers_payload,
        answers_lens,
        fri1_payload: pack(fri1.span()).span(),
        fri1_n: fri1.len(),
        fri2_payload: pack(fri2.span()).span(),
        fri2_n: fri2.len(),
    }
}

#[test]
fn router_five_transactions_n4() {
    let sec = sections();
    let p = plan(@sec);
    let router = deploy_router();
    let me: ContractAddress = test_address();

    // Calldata cap check (payload + echo + arguments, the __execute__ envelope adds ~4).
    assert!(p.begin_payload.len() + p.begin_lens.len() + 5 <= 4990, "begin calldata");

    let s1 = router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
    assert!(router.checkpoint(me, PROOF_ID).tag == TAG_MERKLE, "tag after begin");
    assert!(s1.len() + p.merkle_payload.len() + p.merkle_lens.len() + 7 <= 4990, "merkle cd");

    let s2 = router.merkle(PROOF_ID, s1.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
    let s3 = router.answers(PROOF_ID, s2.span(), p.answers_payload, p.answers_lens);
    assert!(router.checkpoint(me, PROOF_ID).tag == TAG_FRI, "tag after answers");
    assert!(s3.len() + p.fri1_payload.len() + 4 <= 4990, "fri1 calldata");

    let s4 = router.fri(PROOF_ID, s3.span(), p.fri1_payload, p.fri1_n);
    assert!(router.checkpoint(me, PROOF_ID).tag == TAG_FRI, "tag after fri1");
    let _s5 = router.fri(PROOF_ID, s4.span(), p.fri2_payload, p.fri2_n);

    let fact = compute_fact(multiverifier_circuit_hash(), n4_output_hash());
    assert!(router.is_valid(fact), "fact registered");
    assert!(!router.is_valid(fact + 1), "other fact");
    let cp: Checkpoint = router.checkpoint(me, PROOF_ID);
    assert!(cp.tag == TAG_DONE, "tag done");
}

#[test]
#[should_panic(expected: 'router: proof id in use')]
fn router_rejects_proof_id_reuse() {
    let sec = sections();
    let p = plan(@sec);
    let router = deploy_router();
    router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
    router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
}

#[test]
#[should_panic(expected: 'router: wrong phase')]
fn router_rejects_phase_skip() {
    let sec = sections();
    let p = plan(@sec);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
    // `fri` before `answers`: the slot holds a MERKLE tag.
    router.fri(PROOF_ID, s1.span(), p.fri1_payload, p.fri1_n);
}

#[test]
#[should_panic(expected: 'router: bad state echo')]
fn router_rejects_tampered_echo() {
    let sec = sections();
    let p = plan(@sec);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
    let mut tampered = array![];
    let mut first = true;
    for v in s1.span() {
        tampered.append(if first {
            *v + 1
        } else {
            *v
        });
        first = false;
    }
    router.merkle(PROOF_ID, tampered.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
}

#[test]
#[should_panic(expected: 'router: wrong phase')]
fn router_binds_the_caller() {
    let sec = sections();
    let p = plan(@sec);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
    // Another account cannot continue this proof id: its own slot is free (tag 0).
    let other: ContractAddress = 0xdead.try_into().unwrap();
    start_cheat_caller_address(router.contract_address, other);
    router.merkle(PROOF_ID, s1.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
    stop_cheat_caller_address(router.contract_address);
}

#[test]
#[should_panic(expected: "merkle: tree already done")]
fn router_rejects_replayed_merkle_tx() {
    let sec = sections();
    let p = plan(@sec);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.begin_payload, p.begin_lens, array![0, 1].span());
    let s2 = router.merkle(PROOF_ID, s1.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
    // Replaying the same Merkle tx against the new state: trees 2/3 are already done.
    router.merkle(PROOF_ID, s2.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
}
