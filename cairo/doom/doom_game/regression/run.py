#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exact executable regression and a counted, deterministic 10,000-tic fuzz campaign."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import time
from abi import (Failure, check_state, compare, decode_frame, digest, expected_d14,
                 packed, poseidon_hash_many, require)
from corpus import SEED, scenarios, word
from runner import HERE, ROOT, Runner


def provenance():
    return dict(commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                scarb="2.16.0", python=sys.version.split()[0],
                poseidon_py=importlib.metadata.version("poseidon-py"))


def write_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def genesis(runner):
    raw = runner.call("genesis", [0])
    require(raw and raw[0] > 0 and len(raw) == raw[0] + 2, "genesis", "invalid ABI length")
    state = raw[1:-1]
    check_state(state)
    require(state[4:6] == [0, 0], "genesis", "not running at tic zero")
    require(raw[-1] == poseidon_hash_many(state), "genesis", "independent Poseidon hash differs")
    return state


def cut_sizes(length, seed, many):
    rng = random.Random(seed)
    if length < 2:
        return [length]
    if not many:
        first = rng.randrange(1, length)
        return [first, length - first]
    sizes, left = [1], length - 1
    while left:
        size = min(left, rng.randint(17, 113))
        sizes.append(size)
        left -= size
    return sizes


def replay(runner, state, words, seed, many=True, d14_cuts=True, boundary=True):
    require(words and all(0 <= w < 2**32 for w in words), "input", "expected canonical nonempty words")
    whole = decode_frame(runner.call("step_tic", packed(state, words)))
    actual = whole.tic - state[4]
    require(0 < actual <= len(words), "clock", "no advancement or advancement beyond supplied input")
    require(whole.status != 0 or actual == len(words), "clock", "running replay did not consume every word")
    public = runner.call("run_segment", [*packed(state, words), state[4], len(words)])
    compare(public, expected_d14(state, whole, words), "d14_oracle")
    current, offset, previous_public = state, 0, None
    cuts = []
    for size in cut_sizes(len(words), seed, many):
        part = words[offset:offset + size]
        frame = decode_frame(runner.call("step_tic", packed(current, part)))
        consumed = frame.tic - current[4]
        require(0 < consumed <= len(part), "clock", "cut did not advance")
        require(frame.status != 0 or consumed == len(part), "clock", "running cut stopped early")
        if d14_cuts:
            segment = runner.call("run_segment", [*packed(current, part), current[4], len(part)])
            compare(segment, expected_d14(current, frame, part), "d14_cut_oracle")
            if previous_public is not None:
                require(previous_public[2] == segment[1] and previous_public[4] == segment[3]
                        and previous_public[5] == 0, "d14_chain", "hash/time/status discontinuity")
                require(all(a <= b for a, b in zip(previous_public[7:], segment[7:])),
                        "d14_chain", "cumulative stats decreased")
            else:
                require(public[1] == segment[1], "d14_chain", "initial state hash changed")
            previous_public = segment
        cuts.append(consumed)
        offset += consumed
        current = frame.state
        if frame.status != 0:
            break
    compare(frame.raw, whole.raw, "split_equivalence")
    require(sum(cuts) == actual, "clock", "cut advancement count differs")
    if d14_cuts:
        require(previous_public[2] == public[2] and previous_public[4:6] == public[4:6]
                and previous_public[7:] == public[7:], "d14_chain", "final D14 differs from whole")
    if boundary:
        compare(runner.call("step_tic", packed(whole.state, [])), whole.raw, "empty_boundary")
    return whole, public, dict(actual_tics=actual, supplied_tics=len(words),
                               terminal_unconsumed=len(words) - actual, cuts=cuts,
                               serialized_boundaries=max(0, len(cuts) - 1),
                               d14_cut_checks=len(cuts) if d14_cuts else 0,
                               empty_boundary_checks=int(boundary))


def failure_artifact(out, runner, case, error):
    artifact = dict(schema=1, profile=runner.profile, kind=error.kind, error=str(error),
                    case=case, identity=runner.identity, minimized=False,
                    invocation=getattr(runner, "last_call", None))
    write_json(out / "failure.json", artifact)
    for suffix in ("stdout", "stderr"):
        source = Path(getattr(runner, "out", out)) / f"last-{suffix}.txt"
        if source.exists():
            shutil.copyfile(source, out / f"failure-{suffix}.txt")
    # Reuse the exact serialized checkpoint; only reduce its command suffix. This is a bounded
    # delta-debugging search, not a claim of a globally smallest counterexample.
    retain_whole = ("golden", "profile_equivalence", "timeout", "campaign_timeout", "execution")
    if case.get("operation") == "genesis" or "previous_d14" in case or error.kind in retain_whole:
        artifact["minimization"] = "not attempted: full pinned case, setup, execution failure or timeout must be retained"
    else:
        original, reduced = case["words"], list(case["words"])
        tries, started, granularity = 0, time.monotonic(), 2
        previous_deadline = getattr(runner, "deadline", None)
        runner.deadline = min(previous_deadline or float("inf"), started + 120)
        while len(reduced) > 1 and tries < 24 and time.monotonic() - started < 120:
            width = max(1, (len(reduced) + granularity - 1) // granularity)
            changed = False
            for at in range(0, len(reduced), width):
                candidate = reduced[:at] + reduced[at + width:]
                if not candidate or tries >= 24 or time.monotonic() - started >= 120:
                    break
                tries += 1
                try:
                    replay(runner, case["state"], candidate, case["seed"], case["many"],
                           case["d14_cuts"], case["boundary"])
                except Failure as found:
                    if found.kind == error.kind:
                        reduced, changed = candidate, True
                        granularity = max(2, granularity - 1)
                        break
            if not changed:
                if granularity >= len(reduced):
                    break
                granularity = min(len(reduced), granularity * 2)
        runner.deadline = previous_deadline
        artifact["case"] = {**case, "words": reduced}
        artifact["minimized"] = len(reduced) < len(original)
        artifact["minimization"] = dict(attempts=tries, before=len(original), after=len(reduced),
                                        limit_attempts=24, seconds=time.monotonic() - started,
                                        claim="smallest found by bounded deletion search")
    write_json(out / "repro.json", artifact)
    print(f"failure artifacts: {out / 'failure.json'} and {out / 'repro.json'}", flush=True)


def invoke_case(runner, out, state, words, seed, name, many=True, d14_cuts=True, boundary=True):
    case = dict(name=name, state=state, words=words, seed=seed, many=many,
                d14_cuts=d14_cuts, boundary=boundary)
    try:
        return replay(runner, state, words, seed, many, d14_cuts, boundary)
    except Failure as error:
        failure_artifact(out, runner, case, error)
        raise


def invoke_genesis(runner, out, reference=None):
    case = dict(name="genesis", operation="genesis", arguments=[0])
    if reference is not None:
        case["expected_state"] = reference
    try:
        initial = genesis(runner)
        if reference is not None:
            compare(initial, reference, "profile_equivalence")
        return initial
    except Failure as error:
        failure_artifact(out, runner, case, error)
        raise


def check_profile(runner, out, case, frame, public, reference):
    try:
        compare(frame.raw, reference[0], "profile_equivalence")
        compare(public, reference[1], "profile_equivalence")
    except Failure as error:
        failure_artifact(out, runner, {**case, "expected_output": reference[0],
                                       "expected_d14": reference[1]}, error)
        raise


def reproduce(runner, case):
    if case.get("operation") == "genesis":
        state = genesis(runner)
        if "expected_state" in case:
            compare(state, case["expected_state"], "profile_equivalence")
        return
    frame, public, _ = replay(runner, case["state"], case["words"], case["seed"], case["many"],
                              case["d14_cuts"], case["boundary"])
    if "expected_pin" in case:
        pin = dict(input_sha256=digest(case["words"]), **frame.summary(), d14=[hex(x) for x in public])
        require(pin == case["expected_pin"], "golden", f"{case['name']} pinned output differs")
    if "previous_d14" in case:
        previous = case["previous_d14"]
        require(previous[2] == public[1] and previous[4] == public[3] and previous[5] == 0,
                "d14_chain", "successive fuzz batches do not chain")
    if "expected_output" in case:
        compare(frame.raw, case["expected_output"], "profile_equivalence")
        compare(public, case["expected_d14"], "profile_equivalence")


def corpus(args):
    cases = scenarios()
    if args.case:
        cases = [case for case in cases if case["name"] in args.case]
        require(len(cases) == len(set(args.case)), "input", "unknown case")
    else:
        require(len(cases) >= 20, "coverage", "fewer than twenty distinct replays")
    if args.record:
        require(not args.record.exists(), "record", "candidate file already exists; never overwrite pins")
        require(not args.case and set(args.profiles) == {"dev", "proving"},
                "record", "initial pins require complete corpus in both profiles")
        expected = None
    else:
        expected = json.loads(args.goldens.read_text())
    rows, runners, reference = {}, {}, {}
    started = time.monotonic()
    for profile in args.profiles:
        runner = runners[profile] = Runner(profile, args.out / profile, args.timeout, args.target)
        runner.deadline = started + args.max_seconds
        initial = invoke_genesis(runner, args.out, reference.get("genesis"))
        reference.setdefault("genesis", initial)
        rows[profile] = []
        for index, case in enumerate(cases):
            seed = SEED + index * 101
            frame, public, counts = invoke_case(runner, args.out, initial, case["words"], seed, case["name"])
            pin = dict(input_sha256=digest(case["words"]), **frame.summary(), d14=[hex(x) for x in public])
            if expected is not None and expected["cases"][case["name"]] != pin:
                error = Failure("golden", f"{case['name']} pinned output differs")
                failure_artifact(args.out, runner, dict(name=case["name"], state=initial,
                    words=case["words"], seed=seed, many=True, d14_cuts=True, boundary=True,
                    expected_pin=expected["cases"][case["name"]], observed_pin=pin), error)
                raise error
            if case["name"] in reference:
                check_profile(runner, args.out, dict(name=case["name"], state=initial,
                    words=case["words"], seed=seed, many=True, d14_cuts=True, boundary=True),
                    frame, public, reference[case["name"]])
            else:
                reference[case["name"]] = (frame.raw, public, pin)
            row = dict(name=case["name"], purpose=case["purpose"], cut_seed=seed, **counts, **pin)
            rows[profile].append(row)
            write_json(args.out / "progress.json", dict(mode="corpus", profiles=rows))
            print(json.dumps(dict(profile=profile, case=case["name"], tics=frame.tic,
                                  status=frame.status, stats=frame.stats, cuts=len(counts["cuts"]),
                                  seconds=round(time.monotonic() - started, 2))), flush=True)
    first = rows[args.profiles[0]]
    coverage = dict(distinct_inputs=len({r["input_sha256"] for r in first}),
                    distinct_final_states=len({r["state_sha256"] for r in first}),
                    actual_tics=sum(r["actual_tics"] for r in first),
                    terminal_unconsumed=sum(r["terminal_unconsumed"] for r in first),
                    deaths=sum(r["status"] == 1 for r in first), exits=sum(r["status"] == 2 for r in first),
                    cases_with_kills=sum(r["stats"][0] > 0 for r in first),
                    cases_with_items=sum(r["stats"][1] > 0 for r in first),
                    weapon_ids=sorted({r["weapon"] for r in first}))
    if not args.case:
        require(coverage["distinct_final_states"] >= 20 and coverage["deaths"] > 0
                and coverage["cases_with_kills"] > 0 and coverage["cases_with_items"] > 0,
                "coverage", "movement/combat/pickup/death corpus was not actually observed")
    result = dict(ok=True, mode="corpus", provenance=provenance(), seed=SEED, seconds=time.monotonic() - started,
                  coverage=coverage, profiles=rows,
                  identity={p: r.identity for p, r in runners.items()},
                  metrics={p: r.metrics for p, r in runners.items()},
                  checked_outputs={p: observed_outputs(r, sum(c["empty_boundary_checks"] for c in rows[p]))
                                   for p, r in runners.items()})
    write_json(args.out / "result.json", result)
    if args.record:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        write_json(args.record, dict(schema=1, provenance=dict(engine_commit=commit,
            scarb="2.16.0", poseidon_py=importlib.metadata.version("poseidon-py"),
            method="initial characterization: exact dev/proving outputs, random cuts, independent D13/D14 oracle",
            seed=SEED, identity=result["identity"]),
            cases={r["name"]: reference[r["name"]][2] for r in first}))
    print(json.dumps(dict(ok=True, mode="corpus", **coverage, seconds=result["seconds"])), flush=True)


def observed_outputs(runner, empty_checks):
    """Count exposed outputs, not intermediate VM states hidden inside a multi-tic call."""
    snapshots = runner.metrics["step_tic"]["calls"]
    states = snapshots + runner.metrics["genesis"]["calls"]
    return dict(state_outputs=states, snapshot_outputs=snapshots,
                directly_decoded_states=states - empty_checks,
                directly_decoded_snapshots=snapshots - empty_checks,
                empty_outputs_checked_by_exact_equality=empty_checks,
                scope="public call boundaries; not every intermediate tic or VM memory cell")


def random_words(rng, count, raw):
    if raw:
        return [rng.getrandbits(32) for _ in range(count)]
    words = []
    while len(words) < count:
        w = word(rng.choice([-50, 0, 25, 50]), rng.choice([-40, 0, 0, 40]),
                 rng.choice([-2048, -1024, 0, 0, 0, 1024, 2048]),
                 rng.choice([0, 0, 1, 1, 2, 3, 4 | (rng.randrange(7) << 3)]))
        words.extend([w] * min(rng.randint(4, 24), count - len(words)))
    return words


def fuzz(args):
    runner = Runner(args.profile, args.out / args.profile, args.timeout, args.target)
    rng, started = random.Random(args.seed), time.monotonic()
    runner.deadline = started + args.max_seconds
    initial = invoke_genesis(runner, args.out)
    actual, episode, cases, boundaries, d14_cuts, unused = 0, 0, 0, 0, 0, 0
    statuses, rows = {}, []
    routes = {c["name"]: c["words"] for c in scenarios()}
    while actual < args.tics:
        episode += 1
        state, previous = initial, None
        # Real command prefixes enter different rooms before random controls. They are counted
        # in actual_tics, not silently generated states or uncounted warmups.
        prefix = [routes["walk_lift"][:110], routes["door_pickups"][:175],
                  routes["death"][:151], []][(episode - 1) % 4]
        offset = 0
        while state[4] < 1024 and state[5] == 0 and actual < args.tics:
            count = min(64, args.tics - actual, 1024 - state[4])
            words = prefix[offset:offset + count]
            offset += len(words)
            words += random_words(rng, count - len(words), episode % 4 == 0)
            seed = rng.getrandbits(32)
            frame, public, counts = invoke_case(runner, args.out, state, words, seed,
                f"fuzz-{cases}", many=False, d14_cuts=cases % 8 == 0, boundary=cases % 8 == 0)
            if previous is not None:
                try:
                    require(previous[2] == public[1] and previous[4] == public[3] and previous[5] == 0,
                            "d14_chain", "successive fuzz batches do not chain")
                except Failure as error:
                    failure_artifact(args.out, runner, dict(name=f"fuzz-{cases}", state=state,
                        words=words, seed=seed, many=False, d14_cuts=cases % 8 == 0,
                        boundary=cases % 8 == 0, previous_d14=previous), error)
                    raise
            previous = public
            actual += counts["actual_tics"]
            boundaries += counts["serialized_boundaries"]
            d14_cuts += counts["d14_cut_checks"]
            unused += counts["terminal_unconsumed"]
            cases += 1
            statuses[str(frame.status)] = statuses.get(str(frame.status), 0) + 1
            state = frame.state
            rows.append(dict(case=cases - 1, episode=episode, cut_seed=seed,
                             input_sha256=digest(words), **counts, **frame.summary(),
                             d14=[hex(x) for x in public]))
            progress = dict(mode="fuzz", actual_tics=actual, cases=cases, episodes=episode,
                            seconds=round(time.monotonic() - started, 2), statuses=statuses)
            write_json(args.out / "progress.json", progress)
            print(json.dumps(progress), flush=True)
    require(actual == args.tics, "clock", "campaign did not execute its requested number of tics")
    result = dict(ok=True, mode="fuzz", provenance=provenance(), profile=args.profile, seed=args.seed, actual_tics=actual,
                  cases=cases, episodes=episode, serialized_boundaries=boundaries, d14_whole_checks=cases,
                  d14_cut_checks=d14_cuts, terminal_unconsumed=unused, statuses=statuses,
                  seconds=time.monotonic() - started, identity=runner.identity, metrics=runner.metrics,
                  checked_outputs=observed_outputs(runner, sum(c["empty_boundary_checks"] for c in rows)),
                  successive_batch_links=cases - episode, rows=rows)
    write_json(args.out / "result.json", result)
    print(json.dumps({k: v for k, v in result.items() if k not in ("rows", "identity", "metrics")}), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["corpus", "fuzz", "reproduce"])
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--target", type=Path)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--max-seconds", type=int, default=3600)
    ap.add_argument("--profiles", nargs="+", choices=["dev", "proving"], default=["dev", "proving"])
    ap.add_argument("--profile", choices=["dev", "proving"], default="proving")
    ap.add_argument("--case", action="append")
    ap.add_argument("--goldens", type=Path, default=HERE / "goldens.json")
    ap.add_argument("--record", type=Path, help="write a NEW candidate; never overwrite historical pins")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--tics", type=int, default=10_000)
    ap.add_argument("--failure", type=Path)
    args = ap.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    require(args.tics > 0 and args.timeout > 0 and args.max_seconds > 0, "input", "positive limits required")
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    version = subprocess.check_output(["scarb", "--version"], text=True, env=env, timeout=10)
    require(version.splitlines()[0].startswith("scarb 2.16.0"), "toolchain", version)
    try:
        if args.mode == "corpus":
            corpus(args)
        elif args.mode == "fuzz":
            fuzz(args)
        else:
            require(args.failure is not None, "input", "--failure is required")
            saved = json.loads(args.failure.read_text())
            case = saved["case"]
            runner = Runner(saved["profile"], args.out, args.timeout, args.target)
            runner.deadline = time.monotonic() + args.max_seconds
            write_json(args.out / "reproduction.json", dict(original_identity=saved["identity"],
                current_identity=runner.identity, case=case, profile=runner.profile))
            reproduce(runner, case)
            print("counterexample no longer reproduces under these executables")
    except Failure as error:
        write_json(args.out / "error.json", dict(ok=False, kind=error.kind, error=str(error)))
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
