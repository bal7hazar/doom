# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: Apache-2.0
#
# Hellproof wrapper service (P3.4), Linux/amd64 or arm64.
#
# Three build stages so the two expensive ones are cached independently:
#   1. `proving`  — the pinned monorepo's `leaf-prover` and
#                   `stwo_run_and_prove_recursive_tree` (starkware-libs/proving @ cd7bc5f, R3-A1).
#                   ~6 min and several GB of RAM on 12 cores.
#   2. `verifier` — `hellproof-leaf-verify`, the Rust verifier front end (~1 min: it only pulls
#                   `cairo-air`, not the prover).
#   3. `service`  — the wrapper itself (seconds: no monorepo dependency at all).
#
# Build from the repository root:
#   docker build -f infra/wrapper/Dockerfile -t hellproof-wrapper .
#
# Runtime needs ~32.5 GB of RAM per concurrent circuit proof with the `doom` registry (S4) and
# ~21.9 GB with `doom_fold4_min` (S4b). See docker-compose.yml.

ARG PROVING_REV=cd7bc5f4697fb188a27e09f9242f1dd76df8afdc
# The monorepo's own toolchain (its rust-toolchain.toml).
ARG NIGHTLY=nightly-2026-01-15

# ---------------------------------------------------------------------------------------------
FROM rust:1-bookworm AS toolchain
ARG NIGHTLY
RUN apt-get update \
 && apt-get install -y --no-install-recommends git pkg-config libssl-dev cmake clang \
 && rm -rf /var/lib/apt/lists/*
RUN rustup toolchain install "$NIGHTLY" --profile minimal \
 && rustup default "$NIGHTLY"
ENV CARGO_TERM_COLOR=never

# ---------------------------------------------------------------------------------------------
# 1. the pinned prover binaries
FROM toolchain AS proving
ARG PROVING_REV
WORKDIR /src
RUN git clone --filter=blob:none https://github.com/starkware-libs/proving.git proving \
 && cd proving \
 && git checkout "$PROVING_REV"
WORKDIR /src/proving
# `-C target-cpu=native` is deliberately NOT set: the image must run on the host it was built for
# *and* on its neighbours. Add it in a private build if you pin the CPU.
RUN RUSTFLAGS="-C opt-level=3" cargo build --release \
      -p leaf-prover -p stwo-run-and-prove-recursive-tree -p circuit-params
RUN mkdir -p /out/bin /out/data \
 && cp target/release/leaf-prover /out/bin/ \
 && cp target/release/stwo_run_and_prove_recursive_tree /out/bin/ \
 && cp target/release/circuit-params /out/bin/ \
 && cp crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json \
       /out/data/

# ---------------------------------------------------------------------------------------------
# 2. the Rust verifier front end (this repo)
FROM toolchain AS verifier
WORKDIR /src
COPY prover/wrapper/leaf-verify /src/leaf-verify
WORKDIR /src/leaf-verify
RUN cargo build --release --locked \
 && mkdir -p /out/bin \
 && cp target/release/hellproof-leaf-verify /out/bin/

# ---------------------------------------------------------------------------------------------
# 3. the service
FROM rust:1-bookworm AS service
WORKDIR /src
COPY prover/wrapper/Cargo.toml prover/wrapper/Cargo.lock ./
COPY prover/wrapper/src ./src
RUN cargo build --release --locked \
 && mkdir -p /out/bin \
 && cp target/release/hellproof-wrapper /out/bin/

# ---------------------------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates procps curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --uid 10001 hellproof
# `procps` is required: the service samples each child's peak RSS with `ps`.

COPY --from=proving  /out/bin/  /opt/proving/bin/
COPY --from=proving  /out/data/ /opt/proving/data/
COPY --from=verifier /out/bin/  /opt/hellproof/bin/
COPY --from=service  /out/bin/  /opt/hellproof/bin/

# The circuit registry, the pinned programs and the prover parameters travel with the image so a
# container is reproducible on its own (R8-A4: a third party can run their own wrapper).
COPY spikes/s4/registry/doom/registry.json                /opt/hellproof/registry/doom/registry.json
COPY spikes/s4/registry/doom_fold4_min/registry.json      /opt/hellproof/registry/doom_fold4_min/registry.json
COPY prover/wasm/harness/params/leaf.json                 /opt/hellproof/params/leaf.json
COPY infra/wrapper/wrapper.docker.toml                    /opt/hellproof/wrapper.toml

# Both are volume mount points: create them in the image so a named volume inherits the
# unprivileged owner instead of root.
RUN mkdir -p /data /opt/hellproof/programs && chown -R hellproof:hellproof /data /opt/hellproof

ENV WRAPPER_DATA_DIR=/data \
    WRAPPER_BIND=0.0.0.0:8787 \
    RUST_LOG=info
VOLUME ["/data", "/opt/hellproof/programs"]
EXPOSE 8787
USER hellproof

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8787/healthz || exit 1

ENTRYPOINT ["/opt/hellproof/bin/hellproof-wrapper"]
CMD ["--config", "/opt/hellproof/wrapper.toml"]
