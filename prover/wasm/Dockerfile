# Reproducible Linux build of the Hellproof wasm64 prover (R11-A1).
#
#   docker build -t hellproof-prover-wasm -f prover/wasm/Dockerfile prover/wasm
#   docker run --rm hellproof-prover-wasm cat /build/SHA256SUMS
#   docker run --rm -v "$PWD/prover/wasm/dist:/out" hellproof-prover-wasm cp /build/dist/hellproof_prover_wasm.wasm /out/
#
# Everything is pinned: base image digest, nightly channel (rust-toolchain.toml), crate graph
# (Cargo.lock), upstream monorepo commit (Cargo.toml rev = cd7bc5f...).
# The base image only provides rustup + a C toolchain; the actual compiler is the nightly from
# rust-toolchain.toml, installed below. Pin the digest (`docker pull rust:1-slim-bookworm` prints it)
# in CI: `--build-arg BASE=rust:1-slim-bookworm@sha256:<digest>`.
ARG BASE=rust:1-slim-bookworm
FROM ${BASE} AS build

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates pkg-config curl patch \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY rust-toolchain.toml Cargo.toml Cargo.lock ./
COPY .cargo ./.cargo
COPY src ./src
COPY patches ./patches
COPY build.sh ./

# The nightly from rust-toolchain.toml; rust-src is needed for -Z build-std.
RUN rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)" --profile minimal -c rust-src

ENV CARGO_TARGET_DIR=/build/target \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    HOME=/root
RUN mkdir -p harness/public && bash ./build.sh

FROM scratch AS artifact
COPY --from=build /build/dist/hellproof_prover_wasm.wasm /hellproof_prover_wasm.wasm
COPY --from=build /build/SHA256SUMS /SHA256SUMS
