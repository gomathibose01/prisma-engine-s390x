#!/usr/bin/env bash
# ==============================================================================
# compile-prisma-engine-s390x.sh
# ------------------------------------------------------------------------------
# Compiles the Prisma query engine natively for IBM Z (s390x) from Rust source.
#
# This script is needed because Prisma does not officially distribute a
# pre-built engine binary for s390x. This script:
#
#   1. Checks / installs Rust toolchain (1.85+) to /data/rustup
#   2. Clones prisma-engines at the correct version
#   3. Applies the sct patch to fix the ring 0.16 s390x incompatibility
#   4. Compiles query-engine-node-api with all build dirs on /data
#   5. Copies the compiled engine to the cache directory
#   6. Cleans up build artifacts to reclaim disk space
#
# REQUIREMENTS:
#   - IBM Z (s390x) machine
#   - /data filesystem with at least 6 GB free during compilation
#     (can be cleaned back down to ~800 MB after compilation)
#   - Internet access to GitHub and crates.io
#   - curl, git
#
# DISK USAGE (peak during compilation):
#   /data/rustup      ~800 MB  (Rust toolchain — kept after build)
#   /data/cargo       ~500 MB  (Cargo registry — cleaned after build)
#   /data/prisma-build ~4 GB   (build artifacts — cleaned after build)
#   /data/tmp         ~500 MB  (temp files — cleaned after build)
#
# OUTPUT:
#   ~/.build-tools/prisma-engine-s390x/libquery_engine.so.node
#   (or CACHE_DIR if overridden)
#
# USAGE:
#   ./compile-prisma-engine-s390x.sh
#   ./compile-prisma-engine-s390x.sh --version 6.16.2
#   ./compile-prisma-engine-s390x.sh --data-dir /data --cache-dir /opt/prisma-cache
#
# OPTIONS:
#   --version <ver>    Prisma engines version tag  (default: 6.16.2)
#   --data-dir <path>  Base dir for build artifacts (default: /data)
#   --cache-dir <path> Where to cache the compiled engine
#                      (default: <script-dir>/../.build-tools/prisma-engine-s390x)
#   --keep-build       Do not clean build artifacts after compilation
#   --help             Show this help
# ==============================================================================
set -euo pipefail

# ==============================================================================
# DEFAULTS
# ==============================================================================
PRISMA_VERSION="6.16.2"
DATA_DIR="/data"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../.build-tools/prisma-engine-s390x"
KEEP_BUILD=false

# ==============================================================================
# COLORS
# ==============================================================================
if [[ -t 1 ]]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_DIM='\033[2m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''
fi

log()  { echo -e "${C_CYAN}${C_BOLD}[$(date '+%H:%M:%S')] $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}  ✓ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}  ⚠ $*${C_RESET}" >&2; }
fail() { echo -e "${C_RED}${C_BOLD}  ✗ FATAL: $*${C_RESET}" >&2; exit 1; }
info() { echo -e "${C_DIM}    $*${C_RESET}"; }

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   PRISMA_VERSION="$2"; shift ;;
    --data-dir)  DATA_DIR="$2"; shift ;;
    --cache-dir) CACHE_DIR="$2"; shift ;;
    --keep-build) KEEP_BUILD=true ;;
    --help|-h)
      head -50 "$0" | grep "^#" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
      exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

# Derived paths
RUSTUP_HOME="${DATA_DIR}/rustup"
CARGO_HOME="${DATA_DIR}/cargo"
CARGO_TARGET_DIR="${DATA_DIR}/prisma-build"
TMPDIR="${DATA_DIR}/tmp"
ENGINES_SRC="${DATA_DIR}/prisma-engines-src"
FINAL_ENGINE="${CARGO_TARGET_DIR}/release/libquery_engine.so"
CACHED_ENGINE="${CACHE_DIR}/libquery_engine.so.node"

export RUSTUP_HOME CARGO_HOME CARGO_TARGET_DIR TMPDIR

# ==============================================================================
# BANNER
# ==============================================================================
echo ""
echo -e "${C_BOLD}============================================${C_RESET}"
echo -e "${C_BOLD} Prisma Engine s390x Compiler${C_RESET}"
echo    "  Version  : ${PRISMA_VERSION}"
echo    "  Data dir : ${DATA_DIR}"
echo    "  Cache dir: ${CACHE_DIR}"
echo    "  Keep build artifacts: ${KEEP_BUILD}"
echo -e "${C_BOLD}============================================${C_RESET}"
echo ""

START=$SECONDS

# ==============================================================================
# STEP 0 — Preflight checks
# ==============================================================================
log "STEP 0: Preflight checks"

# Must be on s390x
MACHINE="$(uname -m)"
[[ "$MACHINE" == "s390x" ]] || fail "This script is for s390x only (detected: $MACHINE)"
ok "Architecture: s390x"

# Check if cached engine already exists and is valid
if [[ -f "$CACHED_ENGINE" ]]; then
  if file "$CACHED_ENGINE" | grep -q "S/390\|s390\|IBM"; then
    ok "Valid s390x engine already cached at: $CACHED_ENGINE"
    echo ""
    echo -e "${C_GREEN}${C_BOLD}Nothing to do — cached engine is ready.${C_RESET}"
    echo "Delete $CACHED_ENGINE to force recompilation."
    exit 0
  else
    warn "Cached engine exists but is not s390x — recompiling"
    rm -f "$CACHED_ENGINE"
  fi
fi

# Check required tools
for tool in curl git file; do
  command -v "$tool" &>/dev/null || fail "Required tool not found: $tool"
done
ok "Required tools present (curl, git, file)"

# Check /data has enough space (need ~6 GB)
AVAIL_KB=$(df -k "$DATA_DIR" | tail -1 | awk '{print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
info "Available space on $DATA_DIR: ${AVAIL_GB} GB"
if (( AVAIL_GB < 5 )); then
  fail "Need at least 5 GB free on $DATA_DIR (have ${AVAIL_GB} GB). Free up space first."
fi
ok "Sufficient disk space: ${AVAIL_GB} GB available"

# Create required directories
mkdir -p "$DATA_DIR" "$TMPDIR" "$CARGO_TARGET_DIR" "$CACHE_DIR"

# ==============================================================================
# STEP 1 — Install / verify Rust toolchain
# ==============================================================================
log "STEP 1: Rust toolchain setup"

if [[ -x "${CARGO_HOME}/bin/rustc" ]]; then
  RUST_VER=$("${CARGO_HOME}/bin/rustc" --version 2>/dev/null | awk '{print $2}')
  RUST_MAJOR=$(echo "$RUST_VER" | cut -d. -f1)
  RUST_MINOR=$(echo "$RUST_VER" | cut -d. -f2)
  if (( RUST_MAJOR > 1 || ( RUST_MAJOR == 1 && RUST_MINOR >= 85 ) )); then
    ok "Rust $RUST_VER already installed at $CARGO_HOME — skipping install"
    export PATH="${CARGO_HOME}/bin:$PATH"
  else
    warn "Rust $RUST_VER too old (need 1.85+) — upgrading"
    "${CARGO_HOME}/bin/rustup" update stable \
      || fail "rustup update failed"
    export PATH="${CARGO_HOME}/bin:$PATH"
  fi
else
  info "Installing Rust toolchain to $RUSTUP_HOME / $CARGO_HOME..."
  info "This downloads ~800 MB — please wait..."
  export RUSTUP_INIT_SKIP_PATH_CHECK=yes
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y \
      --default-toolchain stable \
      --no-modify-path \
      2>&1 | grep -v "^info: " | grep -v "^$" || true
  export PATH="${CARGO_HOME}/bin:$PATH"
fi

RUST_VER=$(rustc --version)
CARGO_VER=$(cargo --version)
ok "Rust ready: $RUST_VER"
ok "Cargo ready: $CARGO_VER"

# ==============================================================================
# STEP 2 — Clone prisma-engines source
# ==============================================================================
log "STEP 2: Clone prisma-engines v${PRISMA_VERSION}"

if [[ -d "${ENGINES_SRC}/.git" ]]; then
  # Check if it's the right version
  CURRENT_TAG=$(git -C "$ENGINES_SRC" describe --tags 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_TAG" == *"${PRISMA_VERSION}"* ]]; then
    ok "prisma-engines v${PRISMA_VERSION} already cloned — skipping"
  else
    warn "Different version cloned ($CURRENT_TAG) — recloning"
    rm -rf "$ENGINES_SRC"
    _do_clone=true
  fi
else
  _do_clone=true
fi

if [[ "${_do_clone:-false}" == "true" || ! -d "${ENGINES_SRC}/.git" ]]; then
  info "Cloning prisma-engines v${PRISMA_VERSION} (shallow clone)..."
  git clone \
    --depth 1 \
    --branch "${PRISMA_VERSION}" \
    https://github.com/prisma/prisma-engines.git \
    "$ENGINES_SRC" \
    || fail "Failed to clone prisma-engines v${PRISMA_VERSION} — check version tag and network"
fi

ok "prisma-engines source ready at: $ENGINES_SRC"

# ==============================================================================
# STEP 3 — Patch Cargo.toml to fix ring 0.16 s390x incompatibility
# ==============================================================================
log "STEP 3: Apply s390x compatibility patch (sct / ring 0.16 fix)"

cd "$ENGINES_SRC"

# Remove any previously applied patches to start clean
if grep -q "patch.crates-io" Cargo.toml; then
  PATCH_LINE=$(grep -n "\[patch.crates-io\]" Cargo.toml | tail -1 | cut -d: -f1)
  head -n $(( PATCH_LINE - 2 )) Cargo.toml > Cargo.toml.tmp
  mv Cargo.toml.tmp Cargo.toml
  info "Removed previous patch"
fi

# Apply the sct patch:
# Problem: ring v0.16.20 has no s390x assembly support → fails to compile
# Root cause: sct v0.7.0 depends on ring 0.16 specifically
# Fix: patch sct to use v0.7.1+ which depends on ring 0.17 (has s390x support)
cat >> Cargo.toml << 'EOF'

[patch.crates-io]
sct = { git = "https://github.com/rustls/sct.rs", branch = "main" }
EOF

ok "sct patch applied (ring 0.16 → ring 0.17, s390x compatible)"

# Update lockfile to pick up the patch
info "Updating Cargo.lock for the patch..."
CARGO_HOME="$CARGO_HOME" \
CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
TMPDIR="$TMPDIR" \
cargo update -p sct 2>&1 | grep -E "Adding|Removing|Updating" || true

ok "Cargo.lock updated"

# ==============================================================================
# STEP 4 — Compile query-engine-node-api
# ==============================================================================
log "STEP 4: Compile Prisma query engine for s390x"
info "This takes 20-40 minutes on first build..."
info "Build artifacts → $CARGO_TARGET_DIR"
info "Temp files      → $TMPDIR"

COMPILE_START=$SECONDS

CARGO_HOME="$CARGO_HOME" \
CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
TMPDIR="$TMPDIR" \
cargo build \
  --release \
  --workspace \
  -p query-engine-node-api \
  --exclude schema-engine-cli \
  --exclude query-engine-wasm \
  2>&1 | grep -E "^error|^warning: build|Compiling|Finished|error\[" | \
  grep -v "^warning: build failed" || true

COMPILE_ELAPSED=$(( SECONDS - COMPILE_START ))

# ==============================================================================
# STEP 5 — Verify and cache the compiled engine
# ==============================================================================
log "STEP 5: Verify and cache compiled engine"

[[ -f "$FINAL_ENGINE" ]] || \
  fail "Compiled engine not found at $FINAL_ENGINE — compilation may have failed"

# Verify it's an s390x binary
ENGINE_TYPE=$(file "$FINAL_ENGINE")
info "Binary type: $ENGINE_TYPE"
echo "$ENGINE_TYPE" | grep -q "S/390\|s390\|IBM" || \
  fail "Compiled binary is not s390x: $ENGINE_TYPE"

ok "Engine verified as s390x binary"

# Copy to cache
mkdir -p "$CACHE_DIR"
cp "$FINAL_ENGINE" "$CACHED_ENGINE"
ok "Engine cached at: $CACHED_ENGINE"

ENGINE_SIZE=$(du -sh "$CACHED_ENGINE" | cut -f1)
ok "Engine size: $ENGINE_SIZE"

# ==============================================================================
# STEP 6 — Clean up build artifacts
# ==============================================================================
log "STEP 6: Cleanup"

if [[ "$KEEP_BUILD" == "false" ]]; then
  info "Cleaning build artifacts to reclaim disk space..."
  BEFORE=$(df -k "$DATA_DIR" | tail -1 | awk '{print $4}')

  rm -rf "${CARGO_TARGET_DIR}"
  rm -rf "${DATA_DIR}/tmp"
  rm -rf "${CARGO_HOME}/registry/src"  # source downloads only, not compiled
  rm -rf "${ENGINES_SRC}"              # source code no longer needed

  AFTER=$(df -k "$DATA_DIR" | tail -1 | awk '{print $4}')
  FREED_GB=$(( (AFTER - BEFORE) / 1024 / 1024 ))
  ok "Cleaned up — freed approximately ${FREED_GB} GB"
  info "Rust toolchain kept at: ${RUSTUP_HOME} / ${CARGO_HOME}"
  info "Delete those to reclaim ~800 MB if Rust is no longer needed"
else
  warn "--keep-build set — build artifacts NOT cleaned"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
TOTAL_ELAPSED=$(( SECONDS - START ))
echo ""
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD} Prisma s390x Engine Ready!${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"
echo ""
echo    "  Engine version : ${PRISMA_VERSION}"
echo    "  Compiled in    : ${COMPILE_ELAPSED}s"
echo    "  Total time     : ${TOTAL_ELAPSED}s"
echo    "  Cached at      : ${CACHED_ENGINE}"
echo    "  Size           : ${ENGINE_SIZE}"
echo ""
echo    "  Next step: run the fast-track-ui build"
echo    "  cd /home/ibmsys1/fast-track-ui && ./build/make-nodejs-pkg"
echo ""
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"