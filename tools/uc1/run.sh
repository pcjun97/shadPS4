#!/bin/bash
# SPDX-FileCopyrightText: 2026 shadPS4 UC1 Harness
# SPDX-License-Identifier: GPL-2.0-or-later
# tools/uc1/run.sh – reproducible UC1 runner
# Usage: ./tools/uc1/run.sh [null|vulkan] [timeout_seconds] [game_id_or_path]
# Defaults: mode=null timeout=90 game=CUSA03280
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_BIN="$REPO_ROOT/build/shadps4"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
MODE="${1:-null}"
TIMEOUT_SEC="${2:-90}"
GAME_ID="${3:-CUSA03280}"

# Normalize mode
if [[ "$MODE" == "core" ]]; then MODE="null"; fi

# Colors for log
RESULT_SUBDIR="${TIMESTAMP}_${MODE}"
RESULT_PATH="$RESULTS_DIR/$RESULT_SUBDIR"
mkdir -p "$RESULT_PATH"

LOG_STDOUT="$RESULT_PATH/stdout.log"
LOG_STDERR="$RESULT_PATH/stderr.log"
LOG_COMBINED="$RESULT_PATH/combined.log"
LOG_SHAD="$RESULT_PATH/shad_log.txt"
EXIT_CODE_FILE="$RESULT_PATH/exit_code.txt"
CLASSIFY_JSON="$RESULT_PATH/classify.json"
CONFIG_JSON="$REPO_ROOT/user/config.json"

echo "[run.sh] mode=$MODE timeout=$TIMEOUT_SEC game=$GAME_ID timestamp=$TIMESTAMP" | tee "$LOG_COMBINED"
echo "[run.sh] repo=$REPO_ROOT build=$BUILD_BIN" | tee -a "$LOG_COMBINED"
echo "[run.sh] result dir: $RESULT_PATH" | tee -a "$LOG_COMBINED"

# 1. Ensure build exists – incremental build if needed
if [[ ! -x "$BUILD_BIN" ]]; then
  echo "[run.sh] Build not found, configuring..." | tee -a "$LOG_COMBINED"
  PKG_CONFIG_PATH="/home/linuxbrew/.linuxbrew/lib/pkgconfig:/home/linuxbrew/.linuxbrew/opt/systemd/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
  cmake -S "$REPO_ROOT" -B "$REPO_ROOT/build" \
    -DCMAKE_C_COMPILER=/home/linuxbrew/.linuxbrew/bin/gcc-16 \
    -DCMAKE_CXX_COMPILER=/home/linuxbrew/.linuxbrew/bin/g++-16 \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -G Ninja \
    -DSDL_UNIX_CONSOLE_BUILD=ON -DLIBUSB_ENABLE_UDEV=OFF \
    -DCMAKE_PREFIX_PATH="/home/linuxbrew/.linuxbrew" 2>&1 | tee -a "$LOG_COMBINED"
fi
# Incremental build
echo "[run.sh] Building (incremental)..." | tee -a "$LOG_COMBINED"
PKG_CONFIG_PATH="/home/linuxbrew/.linuxbrew/lib/pkgconfig:/home/linuxbrew/.linuxbrew/opt/systemd/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
cmake --build "$REPO_ROOT/build" --parallel 4 2>&1 | tee -a "$LOG_COMBINED" || {
  echo "[run.sh] Build failed" | tee -a "$LOG_COMBINED"
  echo 1 > "$EXIT_CODE_FILE"
  python3 "$SCRIPT_DIR/classify.py" "$RESULT_PATH" 2>&1 | tee -a "$LOG_COMBINED" || true
  exit 1
}

# 2. Ensure portable user dir exists
mkdir -p "$REPO_ROOT/user/log"
mkdir -p "$REPO_ROOT/games"
# Ensure ICD for lavapipe is available (persistent)
MESA_DIR="$REPO_ROOT/tools/mesa"
ICD_FILE="$MESA_DIR/lvp_icd.json"
if [[ ! -f "$ICD_FILE" ]]; then
  echo "[run.sh] Setting up Mesa lavapipe ICD..." | tee -a "$LOG_COMBINED"
  mkdir -p "$MESA_DIR"
  # If /tmp/mesa exists from previous extraction, copy; otherwise download
  if [[ -d /tmp/mesa/usr/lib/x86_64-linux-gnu ]]; then
    cp -a /tmp/mesa/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so "$MESA_DIR/" 2>&1 | tee -a "$LOG_COMBINED" || true
    # Also copy json template
    cat > "$ICD_FILE" <<EOF
{
    "ICD": {
        "api_version": "1.3.255",
        "library_path": "$MESA_DIR/libvulkan_lvp.so"
    },
    "file_format_version": "1.0.0"
}
EOF
  else
    # Fallback: try to download mesa-vulkan-drivers
    if [[ -f mesa-vulkan-drivers_23.2.1-1ubuntu3.1~22.04.4_amd64.deb ]]; then
      echo "[run.sh] Found deb locally" | tee -a "$LOG_COMBINED"
    else
      echo "[run.sh] Downloading mesa-vulkan-drivers..." | tee -a "$LOG_COMBINED"
      (cd "$MESA_DIR" && apt download mesa-vulkan-drivers 2>&1 | tee -a "$LOG_COMBINED") || true
    fi
    dpkg -x "$MESA_DIR"/mesa-vulkan-drivers*.deb "$MESA_DIR/tmp" 2>&1 | tee -a "$LOG_COMBINED" || true
    cp "$MESA_DIR/tmp/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so" "$MESA_DIR/" 2>&1 | tee -a "$LOG_COMBINED" || true
    cat > "$ICD_FILE" <<EOF
{
    "ICD": {
        "api_version": "1.3.255",
        "library_path": "$MESA_DIR/libvulkan_lvp.so"
    },
    "file_format_version": "1.0.0"
}
EOF
  fi
  echo "[run.sh] ICD at $ICD_FILE" | tee -a "$LOG_COMBINED"
  cat "$ICD_FILE" | tee -a "$LOG_COMBINED"
fi

# 3. Set GPU mode in config.json (portable ./user/config.json)
if [[ -f "$CONFIG_JSON" ]]; then
  echo "[run.sh] Setting GPU.null_gpu for mode $MODE" | tee -a "$LOG_COMBINED"
  python3 <<PY 2>&1 | tee -a "$LOG_COMBINED"
import json, pathlib
p = pathlib.Path("$CONFIG_JSON")
j = json.loads(p.read_text())
j["GPU"]["null_gpu"] = True if "$MODE" == "null" else False
# Ensure separate log per game for easier capture
j["Log"]["separate"] = True
j["Log"]["enable"] = True
# Ensure install_dirs points to ./games
import os
games_path = str(pathlib.Path("$REPO_ROOT/games").resolve())
# Keep existing if already correct, else set
if not any(d.get("path")==games_path for d in j["General"]["install_dirs"]):
    j["General"]["install_dirs"] = [{"enabled": True, "path": games_path}]
p.write_text(json.dumps(j, indent=2))
print(f"set null_gpu={j['GPU']['null_gpu']} install_dirs={j['General']['install_dirs']}")
PY
else
  echo "[run.sh] WARNING: $CONFIG_JSON not found, will rely on defaults" | tee -a "$LOG_COMBINED"
fi

# 4. Clean previous per-game log before run
GAME_LOG="$REPO_ROOT/user/log/${GAME_ID}.log"
SHAD_LOG_FALLBACK="$REPO_ROOT/user/log/shad_log.txt"
rm -f "$GAME_LOG" "$SHAD_LOG_FALLBACK"

# 5. Prepare runtime env for brew glibc + vulkan
LD_SO="/home/linuxbrew/.linuxbrew/lib/ld.so"
LIBPATH="/home/linuxbrew/.linuxbrew/Cellar/gcc/16.2.0/lib/gcc/current:/home/linuxbrew/.linuxbrew/Cellar/glibc/2.39_1/lib:/home/linuxbrew/.linuxbrew/lib:/home/linuxbrew/.linuxbrew/Cellar/vulkan-loader/1.4.357.0/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
# Add mesa dirs (persistent and legacy /tmp)
if [[ -d "$MESA_DIR" ]]; then
  LIBPATH="$MESA_DIR:$LIBPATH"
fi
if [[ -d /tmp/mesa/usr/lib/x86_64-linux-gnu ]]; then
  LIBPATH="/tmp/mesa/usr/lib/x86_64-linux-gnu:$LIBPATH"
fi
export VK_ICD_FILENAMES="$ICD_FILE"
export LD_LIBRARY_PATH="/home/linuxbrew/.linuxbrew/lib:/home/linuxbrew/.linuxbrew/Cellar/gcc/16.2.0/lib/gcc/current:${LD_LIBRARY_PATH:-}"

echo "[run.sh] VK_ICD_FILENAMES=$VK_ICD_FILENAMES" | tee -a "$LOG_COMBINED"
echo "[run.sh] LD_LIBRARY_PATH=$LD_LIBRARY_PATH" | tee -a "$LOG_COMBINED"
echo "[run.sh] Launching: $BUILD_BIN $GAME_ID with timeout $TIMEOUT_SEC" | tee -a "$LOG_COMBINED"

# 6. Run with timeout, capture stdout/stderr, exit code
set +e
timeout "$TIMEOUT_SEC" "$LD_SO" --library-path "$LIBPATH" "$BUILD_BIN" "$GAME_ID" > "$LOG_STDOUT" 2> "$LOG_STDERR"
EXIT_CODE=$?
set -e
echo "$EXIT_CODE" > "$EXIT_CODE_FILE"
echo "[run.sh] Exit code: $EXIT_CODE" | tee -a "$LOG_COMBINED"

# If timeout, exit code is 124
if [[ $EXIT_CODE -eq 124 ]]; then
  echo "[run.sh] Timeout after $TIMEOUT_SEC seconds (exit 124)" | tee -a "$LOG_COMBINED"
fi
# Check for signal (128+signal)
if [[ $EXIT_CODE -gt 128 ]]; then
  echo "[run.sh] Terminated by signal $((EXIT_CODE-128))" | tee -a "$LOG_COMBINED"
fi

# 7. Capture shadPS4 log
if [[ -f "$GAME_LOG" ]]; then
  cp "$GAME_LOG" "$LOG_SHAD" 2>&1 | tee -a "$LOG_COMBINED" || true
  echo "[run.sh] Copied per-game log $GAME_LOG -> $LOG_SHAD" | tee -a "$LOG_COMBINED"
elif [[ -f "$SHAD_LOG_FALLBACK" ]]; then
  cp "$SHAD_LOG_FALLBACK" "$LOG_SHAD" 2>&1 | tee -a "$LOG_COMBINED" || true
  echo "[run.sh] Copied fallback log $SHAD_LOG_FALLBACK -> $LOG_SHAD" | tee -a "$LOG_COMBINED"
else
  echo "[run.sh] No shad log found (searched $GAME_LOG and $SHAD_LOG_FALLBACK)" | tee -a "$LOG_COMBINED"
  # Still create empty
  touch "$LOG_SHAD"
fi

# Combine stdout/stderr for convenience
cat "$LOG_STDOUT" "$LOG_STDERR" > "$LOG_COMBINED.tmp" 2>&1 || true
cat "$LOG_COMBINED" "$LOG_COMBINED.tmp" > "$RESULT_PATH/full.log" 2>&1 || true
mv "$RESULT_PATH/full.log" "$LOG_COMBINED" 2>&1 || true

# 8. Classify
echo "[run.sh] Classifying..." | tee -a "$LOG_COMBINED"
python3 "$SCRIPT_DIR/classify.py" "$RESULT_PATH" 2>&1 | tee -a "$LOG_COMBINED" || true
cat "$CLASSIFY_JSON" 2>&1 | tee -a "$LOG_COMBINED" || true

# 9. Return useful exit status: 0 if not crashed and timeout==false, else 1
# Let classify.py decide; we return 0 only if launch succeeded and no fatal
if [[ -f "$CLASSIFY_JSON" ]]; then
  CRASHED=$(python3 -c "import json;print(json.load(open('$CLASSIFY_JSON')).get('crashed', True))")
  if [[ "$CRASHED" == "False" ]]; then
    echo "[run.sh] Run classified as not crashed" | tee -a "$LOG_COMBINED"
    exit 0
  else
    echo "[run.sh] Run crashed per classify" | tee -a "$LOG_COMBINED"
    exit 1
  fi
else
  exit $EXIT_CODE
fi
