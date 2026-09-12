# Embedded resources

| File | Origin | Provenance |
|---|---|---|
| `leaf_simple_bootloader_compiled.json.gz` | `crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json` in starkware-libs/proving @ `cd7bc5f4697fb188a27e09f9242f1dd76df8afdc` — the leaf program of the `canonical_small` circuit registry (`circuit_registry_definitions/canonical_small/definition.json`) | `gzip -9 -n` of the unmodified file; sha256 of the JSON: `5e2befae48dcdea8d19dc655e40ac236285d049d12573bfb341bec9ce39182f5` (verify with `gunzip -c … \| shasum -a 256`) |

Embedded with `include_bytes!` in `src/core.rs` and gunzipped at first use (`flate2`, pure Rust).
The 25 MB `simple_bootloader_compiled.json` (generic simple bootloader with `debug_info`) was not
used: the leaf variant is the program the recursion route proves and is 1.5 MB uncompressed.
