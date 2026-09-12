// SPDX-License-Identifier: Apache-2.0
//! The deployed router driven end-to-end over a real root proof with the 5-transaction plan of
//! `tools/emit_calldata.py` (packed payloads, state echoes), then the sequencing / binding
//! rejections: proof-id reuse, phase skip, tampered echo, foreign caller, replayed tx.
//! The fixture is selected by `fixtures/selected.txt` (see `stwo_circuit_phases/tests/fixture.cairo`).
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
use stwo_circuit_phases::pack::{pack, pack_u32};
use stwo_circuit_phases::sections::{Sections, fri_chunk, split};

const PROOF_ID: felt252 = 0x1;

#[derive(Drop)]
struct Fixture {
    sections: Sections,
    output_hash: [u32; 8],
    multiverifier_hash: [u32; 8],
}

/// `1` = n4 (registry `doom`, production multiverifier hash), `2` = n2_fold4min (registry
/// `doom_fold4_min`); expected hashes as in `stwo_circuit_phases/tests/fixture.cairo`.
fn fixture() -> Fixture {
    let sel = read_txt(@FileTrait::new("../../fixtures/selected.txt"));
    let fold4min = *sel.at(0) == 2;
    let (path, n_felts): (ByteArray, u32) = if fold4min {
        ("../../fixtures/n2_fold4min_root_proof.txt", 96509)
    } else {
        ("../../fixtures/n4_root_proof.txt", 96033)
    };
    let values = read_txt(@FileTrait::new(path));
    assert!(values.len() == n_felts, "fixture length");
    if fold4min {
        Fixture {
            sections: split(values.span()),
            output_hash: [
                3728663878, 1670890090, 2536343223, 1016822265, 1923844992, 548677462,
                1938506889, 1214927871,
            ],
            multiverifier_hash: [
                0x02b34360, 0xcf03feac, 0x315fdae9, 0xbc006aeb, 0x398199e8, 0x57cb9591,
                0x6ab22e55, 0x9f7fac34,
            ],
        }
    } else {
        Fixture {
            sections: split(values.span()),
            output_hash: [
                3123785184, 3718676270, 1469581383, 660429404, 3277334853, 1494218902,
                3817731027, 3170188775,
            ],
            multiverifier_hash: [
                0xa5989715, 0x2377c07a, 0xc6d1e844, 0x54f0a04d, 0x8be65a7d, 0xfd73c261,
                0x9078e728, 0x973f680f,
            ],
        }
    }
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

/// `(payload, lens)`: the fast-path packing of each section, concatenated.
fn payload(sections: Span<Span<felt252>>) -> (Span<felt252>, Span<u32>) {
    let mut slots = array![];
    let mut lens = array![];
    for s in sections {
        slots.append_span(pack_u32(*s).span());
        lens.append((*s).len());
    }
    (slots.span(), lens.span())
}

#[derive(Drop)]
struct Plan {
    head: Span<felt252>,
    head_n: u32,
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
            sec.queried_values.at(0).span(), sec.decommitments.at(0).span(),
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
        head: pack(sec.head.span()).span(),
        head_n: sec.head.len(),
        begin_payload,
        begin_lens,
        merkle_payload,
        merkle_lens,
        answers_payload,
        answers_lens,
        fri1_payload: pack_u32(fri1.span()).span(),
        fri1_n: fri1.len(),
        fri2_payload: pack_u32(fri2.span()).span(),
        fri2_n: fri2.len(),
    }
}

/// Calldata felts of an invoke (the `__execute__` envelope adds ~4): every tx must fit 4 990.
const MAX_CALLDATA: u32 = 4990;

#[test]
fn router_five_transactions() {
    let fx = fixture();
    let p = plan(@fx.sections);
    let router = deploy_router();
    let me: ContractAddress = test_address();

    let cd1 = 1 + 1 + p.head.len() + 1 + 1 + p.begin_payload.len() + 1 + p.begin_lens.len() + 3;
    assert!(cd1 <= MAX_CALLDATA, "begin calldata");
    let s1 = router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
    assert!(router.checkpoint(me, PROOF_ID).tag == TAG_MERKLE, "tag after begin");

    let cd2 = 1 + 1 + s1.len() + 1 + p.merkle_payload.len() + 1 + p.merkle_lens.len() + 3;
    assert!(cd2 <= MAX_CALLDATA, "merkle calldata");
    let s2 = router.merkle(PROOF_ID, s1.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());

    let cd3 = 1 + 1 + s2.len() + 1 + p.answers_payload.len() + 1 + p.answers_lens.len();
    assert!(cd3 <= MAX_CALLDATA, "answers calldata");
    let s3 = router.answers(PROOF_ID, s2.span(), p.answers_payload, p.answers_lens);
    assert!(router.checkpoint(me, PROOF_ID).tag == TAG_FRI, "tag after answers");

    let cd4 = 1 + 1 + s3.len() + 1 + p.fri1_payload.len() + 1;
    assert!(cd4 <= MAX_CALLDATA, "fri1 calldata");
    let s4 = router.fri(PROOF_ID, s3.span(), p.fri1_payload, p.fri1_n);
    assert!(router.checkpoint(me, PROOF_ID).tag == TAG_FRI, "tag after fri1");

    let cd5 = 1 + 1 + s4.len() + 1 + p.fri2_payload.len() + 1;
    assert!(cd5 <= MAX_CALLDATA, "fri2 calldata");
    let _s5 = router.fri(PROOF_ID, s4.span(), p.fri2_payload, p.fri2_n);

    println!("calldata felts: begin {} merkle {} answers {} fri1 {} fri2 {}", cd1, cd2, cd3, cd4, cd5);
    let fact = compute_fact(fx.multiverifier_hash, fx.output_hash);
    assert!(router.is_valid(fact), "fact registered");
    assert!(!router.is_valid(fact + 1), "other fact");
    let cp: Checkpoint = router.checkpoint(me, PROOF_ID);
    assert!(cp.tag == TAG_DONE, "tag done");
}

#[test]
#[should_panic(expected: 'router: proof id in use')]
fn router_rejects_proof_id_reuse() {
    let fx = fixture();
    let p = plan(@fx.sections);
    let router = deploy_router();
    router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
    router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
}

#[test]
#[should_panic(expected: 'router: wrong phase')]
fn router_rejects_phase_skip() {
    let fx = fixture();
    let p = plan(@fx.sections);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
    // `fri` before `answers`: the slot holds a MERKLE tag.
    router.fri(PROOF_ID, s1.span(), p.fri1_payload, p.fri1_n);
}

#[test]
#[should_panic(expected: 'router: bad state echo')]
fn router_rejects_tampered_echo() {
    let fx = fixture();
    let p = plan(@fx.sections);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
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
    let fx = fixture();
    let p = plan(@fx.sections);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
    // Another account cannot continue this proof id: its own slot is free (tag 0).
    let other: ContractAddress = 0xdead.try_into().unwrap();
    start_cheat_caller_address(router.contract_address, other);
    router.merkle(PROOF_ID, s1.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
    stop_cheat_caller_address(router.contract_address);
}

#[test]
#[should_panic(expected: "merkle: tree already done")]
fn router_rejects_replayed_merkle_tx() {
    let fx = fixture();
    let p = plan(@fx.sections);
    let router = deploy_router();
    let s1 = router.begin(PROOF_ID, p.head, p.head_n, p.begin_payload, p.begin_lens, array![0, 1].span());
    let s2 = router.merkle(PROOF_ID, s1.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
    // Replaying the same Merkle tx against the new state: trees 2/3 are already done.
    router.merkle(PROOF_ID, s2.span(), p.merkle_payload, p.merkle_lens, array![2, 3].span());
}
