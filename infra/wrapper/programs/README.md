# Programs the wrapper may prove

Drop the compiled Scarb executables (`*.executable.json`) the wrapper is allowed to prove leaves
for in this directory. `docker-compose.yml` bind-mounts it read-only at `/opt/hellproof/programs`,
and each one must be listed in a `[[programs]]` entry of the configuration — with its
`hash_function` and, ideally, its pinned `program_hash`.

Clients never upload code: they name a program id from that list.

Nothing here is committed.
