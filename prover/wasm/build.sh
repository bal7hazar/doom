#!/usr/bin/env bash
# Reproducible WASM64 (Memory64) build of the Hellproof prover.
#
#   ./build.sh                 # vendor + wasm64 build (monorepo fetched from GitHub at the pinned commit)
#   ./build.sh vendor          # only fetch/patch the vendored sources (needed before any plain `cargo` command)
#   PROVING_SRC=/path/to/proving ./build.sh   # take the monorepo from a local clone instead of GitHub
#   WASM_OPT=1 ./build.sh      # additionally run wasm-opt (binaryen >= 119 for --enable-memory64)
#   NATIVE=1 ./build.sh        # also build the native reference binary
#   NO_SIMD=1 ./build.sh       # build without +simd128 (comparison build)
#
# Outputs: dist/hellproof_prover_wasm.wasm, SHA256SUMS, harness/public/hellproof_prover_wasm.wasm
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

TARGET=wasm64-unknown-unknown
UPSTREAM_REV=cd7bc5f4697fb188a27e09f9242f1dd76df8afdc
UPSTREAM_URL=https://github.com/starkware-libs/proving
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HERE/target}"
export CARGO_TARGET_DIR
TOOLCHAIN="$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)"

# ---- vendor: monorepo at the pinned commit + patches/proving-*.patch ----------------------------
vendor_proving() {
  local dir="$HERE/vendor/proving"
  if [[ -f "$dir/.patched" && "$(cat "$dir/.patched")" == "$UPSTREAM_REV $(cat "$HERE"/patches/proving-*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)" ]]; then
    return 0
  fi
  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$HERE/vendor"
    if [[ -n "${PROVING_SRC:-}" ]]; then
      git clone -q "$PROVING_SRC" "$dir"
    else
      git clone -q --filter=blob:none "$UPSTREAM_URL" "$dir"
    fi
  fi
  git -C "$dir" fetch -q "${PROVING_SRC:-origin}" "$UPSTREAM_REV" 2>/dev/null || true
  git -C "$dir" checkout -q --force "$UPSTREAM_REV"
  git -C "$dir" reset -q --hard "$UPSTREAM_REV"
  git -C "$dir" clean -qfd
  shopt -s nullglob
  for p in "$HERE"/patches/proving-*.patch; do
    echo "applying $(basename "$p") to vendor/proving" >&2
    git -C "$dir" apply --index "$p"
  done
  shopt -u nullglob
  echo "$UPSTREAM_REV $(cat "$HERE"/patches/proving-*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)" > "$dir/.patched"
}

# ---- vendor: crates.io crates + patches/<crate>-<version>-*.patch --------------------------------
# The exact crates.io tarball is fetched and checked against a recorded checksum. Our own
# Cargo.lock records the *patched* (path) source once it has been regenerated, so the checksum is
# looked up in the upstream monorepo's Cargo.lock as well — it pins the same version.
lock_checksum() {
  local crate="$1" version="$2" lock="$3"
  [[ -f "$lock" ]] || return 0
  awk -v n="$crate" -v v="$version" '
    $0=="[[package]]"{name="";ver=""}
    /^name = /{gsub(/"/,"",$3);name=$3}
    /^version = /{gsub(/"/,"",$3);ver=$3}
    /^checksum = / && name==n && ver==v {gsub(/"/,"",$3);print $3}' "$lock"
}

vendor_crate() {
  local crate="$1" version="$2"
  local dir="$HERE/vendor/$crate"
  [[ -f "$dir/.patched" ]] && return 0
  local sum
  sum="$(lock_checksum "$crate" "$version" "$HERE/Cargo.lock")"
  [[ -n "$sum" ]] || sum="$(lock_checksum "$crate" "$version" "$HERE/vendor/proving/Cargo.lock")"
  [[ -n "$sum" ]] || { echo "no checksum for $crate $version in Cargo.lock nor vendor/proving/Cargo.lock" >&2; exit 1; }
  mkdir -p "$HERE/vendor"
  local tgz="$HERE/vendor/$crate-$version.crate"
  [[ -f "$tgz" ]] || curl -fsSL -o "$tgz" "https://static.crates.io/crates/$crate/$crate-$version.crate"
  echo "$sum  $tgz" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch for $tgz" >&2; exit 1; }
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xzf "$tgz" -C "$dir" --strip-components=1
  shopt -s nullglob
  for p in "$HERE"/patches/"$crate"-"$version"-*.patch; do
    echo "applying $(basename "$p") to vendor/$crate" >&2
    patch -p1 -d "$dir" --silent < "$p"
  done
  shopt -u nullglob
  touch "$dir/.patched"
}

vendor_proving
vendor_crate xxhash-rust 0.8.18
[[ "${1:-}" == "vendor" ]] && { echo "vendored." >&2; exit 0; }

# ---- toolchain ------------------------------------------------------------------------------------
echo "toolchain: $TOOLCHAIN  target: $TARGET  upstream: $UPSTREAM_REV" >&2
rustup toolchain list | grep -q "^$TOOLCHAIN" || rustup toolchain install "$TOOLCHAIN" --profile minimal -c rust-src
rustup component list --toolchain "$TOOLCHAIN" --installed | grep -q '^rust-src' || rustup component add rust-src --toolchain "$TOOLCHAIN"

# ---- wasm64 build -------------------------------------------------------------------------------
# The target rustflags live in .cargo/config.toml; a target-specific env var *replaces* them, so
# they are repeated here with the reproducibility flags (strip absolute paths of source/registry).
SIMD=",+simd128"; [[ "${NO_SIMD:-0}" == "1" ]] && SIMD=""
export CARGO_TARGET_WASM64_UNKNOWN_UNKNOWN_RUSTFLAGS="--cfg getrandom_backend=\"custom\" \
 -C target-feature=+bulk-memory,+nontrapping-fptoint,+sign-ext,+mutable-globals$SIMD \
 -C link-arg=--max-memory=17179869184 -C link-arg=-zstack-size=16777216 \
 --remap-path-prefix=$HERE=/hellproof --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo \
 --remap-path-prefix=$CARGO_TARGET_DIR=/target"

# NOTE: with -Z build-std cargo also resolves the sysroot workspace, for which every [patch] is
# unused; the "patch ... was not used in the crate graph" warnings it prints are spurious.
cargo +"$TOOLCHAIN" build --release --lib \
  --target "$TARGET" \
  -Z build-std=std,panic_abort

mkdir -p dist harness/public
WASM="$CARGO_TARGET_DIR/$TARGET/release/hellproof_prover_wasm.wasm"
cp "$WASM" dist/hellproof_prover_wasm.wasm

if [[ "${WASM_OPT:-0}" == "1" ]]; then
  command -v wasm-opt >/dev/null || { echo "wasm-opt not found (binaryen)" >&2; exit 1; }
  wasm-opt --version >&2
  wasm-opt --enable-memory64 --enable-simd --enable-bulk-memory --enable-nontrapping-float-to-int \
    --enable-sign-ext --enable-mutable-globals -O2 \
    dist/hellproof_prover_wasm.wasm -o dist/hellproof_prover_wasm.opt.wasm
  mv dist/hellproof_prover_wasm.opt.wasm dist/hellproof_prover_wasm.wasm
fi

cp dist/hellproof_prover_wasm.wasm harness/public/hellproof_prover_wasm.wasm
(cd dist && shasum -a 256 hellproof_prover_wasm.wasm) > SHA256SUMS
echo "built: dist/hellproof_prover_wasm.wasm ($(du -h dist/hellproof_prover_wasm.wasm | cut -f1))" >&2
cat SHA256SUMS >&2

# ---- optional: native reference ------------------------------------------------------------------
if [[ "${NATIVE:-0}" == "1" ]]; then
  cargo +"$TOOLCHAIN" build --release --bin hellproof-prover-native
  echo "native: $CARGO_TARGET_DIR/release/hellproof-prover-native" >&2
fi
