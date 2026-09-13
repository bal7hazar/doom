# Programs the wrapper may prove

Drop the compiled Scarb executables (`*.executable.json`) the wrapper is allowed to prove leaves
for in this directory. `docker-compose.yml` bind-mounts it read-only at `/opt/hellproof/programs`,
and each one must be listed in a `[[programs]]` entry of the configuration — with its
`hash_function` and its mandatory `program_hash` for subprocess/from_proof.
The output layout defaults to `d14` (eleven felts including task hash and version 1).
Old S4 `segment_stub` fixtures require explicit `output_layout = "legacy_stub"`.
The task hash must be measured from that exact executable; the leaf verifier's
reported bootloader hash is a different value. See the measurement command in
[`prover/wrapper/README.md`](../../../prover/wrapper/README.md#task-identity-at-admission-d19--d31).

The default example uses the committed `client/public/programs/segment_stub10.executable.json`.
Copy that exact artifact here, or update both the executable and measured task pin
in a mounted configuration. Rebuilding it may produce a different hash.

Clients never upload code: they name a program id from that list.

Nothing here is committed.
