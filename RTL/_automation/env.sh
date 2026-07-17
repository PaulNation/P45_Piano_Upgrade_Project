#!/usr/bin/env bash
# _automation/env.sh — Diamond FPGA environment initialization
# Source this file once per shell session from the repo root:
#   source _automation/env.sh
#
# Do NOT execute directly (./env.sh) — it must be sourced so that
# exported variables reach the calling shell.

# ── Guard: must be sourced, not executed ──────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: This script must be sourced, not executed." >&2
  echo "       Run: source _automation/env.sh" >&2
  exit 1
fi

# NOTE: Do NOT use set -e in sourced scripts — it applies to the calling shell
# and will kill the terminal if any sub-command fails (e.g. diamond_env).
# Use explicit error checks below instead.

# ── Step 1 — Locate self and set AUTOMATION_ROOT ─────────────────────────────
AUTOMATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Step 2 — Load machine-local paths ────────────────────────────────────────
if [ ! -f "$AUTOMATION_ROOT/paths.cfg" ]; then
  echo "ERROR: _automation/paths.cfg not found." >&2
  echo "       Copy _automation/paths.cfg.example to _automation/paths.cfg" >&2
  echo "       and fill in your local tool paths." >&2
  return 1
fi

# shellcheck source=/dev/null
source "$AUTOMATION_ROOT/paths.cfg"

# Validate required variables are set and non-empty
for var in DIAMOND_INSTALL QUESTA_BIN; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in _automation/paths.cfg" >&2
    return 1
  fi
done

# ── Step 3 — Locate Diamond binaries ─────────────────────────────────────────
DIAMOND_BIN="$DIAMOND_INSTALL/bin/lin64"
DIAMONDC="$DIAMOND_BIN/diamondc"

if [ ! -x "$DIAMONDC" ]; then
  echo "ERROR: Diamond batch binary not found: $DIAMONDC" >&2
  echo "       Check DIAMOND_INSTALL in _automation/paths.cfg" >&2
  return 1
fi

# diamond_env uses $bindir internally — must be exported before sourcing.
export bindir="$DIAMOND_BIN"

# Source Diamond shell environment (sets LD_LIBRARY_PATH, license vars, etc.)
# Disable exit-on-error around Lattice's script — it may use exit or fail cmds.
# shellcheck source=/dev/null
source "$bindir/diamond_env" || { echo "WARNING: diamond_env returned non-zero (may be harmless)" >&2; }

# ── Step 4 — Validate Diamond version ────────────────────────────────────────
# diamondc -version does not exist on Linux — extract version from install path.
ACTUAL_VER=$(echo "$DIAMOND_INSTALL" | grep -oP '\d+\.\d+' | head -1)
DIAMOND_MIN_VERSION="3.14"

if ! awk "BEGIN { exit !(${ACTUAL_VER:-0} >= $DIAMOND_MIN_VERSION) }"; then
  echo "ERROR: Diamond $DIAMOND_MIN_VERSION required; found ${ACTUAL_VER:-unknown}" >&2
  return 1
fi

# ── Step 5 — Locate and validate Questa Sim ──────────────────────────────────
VSIM="$QUESTA_BIN/vsim"
VLOG="$QUESTA_BIN/vlog"
VCOM="$QUESTA_BIN/vcom"

for bin in "$VSIM" "$VLOG" "$VCOM"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: Questa binary not found: $bin" >&2
    echo "       Check QUESTA_BIN in _automation/paths.cfg" >&2
    return 1
  fi
done

export PATH="$QUESTA_BIN:$PATH"
export QUESTA_BIN

# ── Step 6a — Locate and add Verilator to PATH ───────────────────────────────
# Check standard locations for oss-cad-suite (GitHub Actions runner common location)
OSS_CAD_SUITE="${HOME}/oss-cad-suite/bin:${OSS_CAD_SUITE_BIN:+${OSS_CAD_SUITE_BIN}}"
if [ -d "${HOME}/oss-cad-suite/bin" ]; then
  export PATH="${HOME}/oss-cad-suite/bin:$PATH"
elif command -v verilator &>/dev/null; then
  # Verilator already in PATH
  :
else
  echo "WARNING: verilator not found (checked ${HOME}/oss-cad-suite/bin and PATH)" >&2
fi

# ── Step 6 — Export environment markers ──────────────────────────────────────
export DIAMOND_BIN                           # path to bin/lin64/ — headless + GUI
export DIAMOND_GUI="$DIAMOND_BIN/diamond"   # GUI binary, distinct from diamondc
export DIAMONDC
export AUTOMATION_ROOT
export DIAMOND_ENV_SOURCED=1

# ── Step 7 — Confirm and print summary ───────────────────────────────────────
QUESTA_VER=$(echo "exit" | "$VSIM" -version 2>&1 | grep -oP '\d+\.\d+' | head -1)

echo ""
echo "Diamond FPGA environment ready"
echo "  Diamond:    ${ACTUAL_VER}  (min: $DIAMOND_MIN_VERSION)  ($DIAMONDC)"
echo "  Questa:     ${QUESTA_VER:-unknown}  ($VSIM)"
echo "  Automation: $AUTOMATION_ROOT"
echo ""

