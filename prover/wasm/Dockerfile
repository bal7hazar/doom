# Reproducible Linux build of the Hellproof wasm64 prover (R11-A1).
#
#   docker build --platform linux/arm64 -o out -f prover/wasm/Dockerfile prover/wasm
#   cat out/SHA256SUMS
#
# Compiler/source inputs are pinned: base image digest, nightly channel (rust-toolchain.toml), crate graph
# (Cargo.lock), upstream monorepo commit (Cargo.toml rev = cd7bc5f...), patches/.
# The base image only provides rustup + a C toolchain; the actual compiler is the nightly from
# rust-toolchain.toml, installed below. This digest is the image index resolved in CI run
# 34707523047; linux/arm64 selects its aedeeec296c1... manifest. The committed Linux hashes
# cover this host architecture only (the output target remains wasm64-unknown-unknown).
ARG BASE=rust:1-slim-bookworm@sha256:ebd900bae66fd508b466cef82d64a83a5fb34682e4c8b2797a42908bddc95a57
FROM ${BASE} AS build

RUN test "$(uname -m)" = aarch64 || { echo "Use --platform linux/arm64: SHA256SUMS.linux covers arm64 only" >&2; exit 1; }

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates pkg-config curl patch \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY rust-toolchain.toml Cargo.toml Cargo.lock ./
COPY .cargo ./.cargo
COPY src ./src
COPY resources ./resources
COPY patches ./patches
COPY build.sh ./

# The nightly from rust-toolchain.toml; rust-src is needed for -Z build-std (and for the threaded
# variant, whose std is rebuilt from the patched copy of those sources).
RUN rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)" --profile minimal -c rust-src

ENV CARGO_TARGET_DIR=/build/target \
    CARGO_BUILD_JOBS=2 \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    HOME=/root
# Both variants (single-threaded + threads), no wasm-opt: the shipped artifacts are the raw linker
# output (see README §Artifact size — `wasm-opt -O3` shrinks the file but *grows* the gzip).
RUN mkdir -p harness/public pkg/wasm && bash ./build.sh

FROM scratch AS artifact
COPY --from=build /build/dist/hellproof_prover_wasm.wasm /hellproof_prover_wasm.wasm
COPY --from=build /build/dist/hellproof_prover_wasm.threads.wasm /hellproof_prover_wasm.threads.wasm
COPY --from=build /build/SHA256SUMS /SHA256SUMS
