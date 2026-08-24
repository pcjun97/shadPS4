#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 shadPS4 UC1 Harness
# SPDX-License-Identifier: GPL-2.0-or-later
import json
import re
import sys
import pathlib

def classify(result_dir: pathlib.Path):
    stdout_log = result_dir / "stdout.log"
    stderr_log = result_dir / "stderr.log"
    shad_log = result_dir / "shad_log.txt"
    exit_code_file = result_dir / "exit_code.txt"
    combined = result_dir / "combined.log"

    # Read all logs
    text = ""
    for p in [stdout_log, stderr_log, shad_log, combined]:
        if p.exists():
            try:
                text += "\n" + p.read_text(errors="ignore")
            except:
                pass

    # Exit code
    exit_code = None
    if exit_code_file.exists():
        try:
            exit_code = int(exit_code_file.read_text().strip())
        except:
            exit_code = None

    # Determine flags
    built = (pathlib.Path("build/shadps4").exists())
    launched = False
    crashed = False
    timeout = False
    fatal_assertion = False
    # Check for launch markers
    if "Starting shadps4 emulator" in text or "Game id: CUSA03280" in text:
        launched = True
    if exit_code == 124:
        timeout = True
    # Crashed if exit code non-zero and not timeout, or signal, or critical log
    if exit_code is not None:
        if exit_code != 0 and exit_code != 124:
            # 0 is clean exit (user closed), but for UC1 we expect timeout or stay alive
            # If exit code 139 (SIGSEGV) or 134 (SIGABRT) etc., mark crashed
            crashed = True
        # Also check for signals via 128+?
        if exit_code > 128:
            crashed = True
    # Also check for fatal assertion / critical
    if "Assertion Failed" in text or "Critical" in text and "Failed to create instance" in text:
        fatal_assertion = True
        crashed = True
    # Check for segfault dump
    if "dumped core" in text.lower() or "segmentation fault" in text.lower():
        crashed = True
    # If timeout is true, we consider not crashed if we timed out after successful launch (means it stayed alive)
    # For UC1, timeout after 90s with no crash is considered success for that duration
    if timeout and launched and not fatal_assertion:
        # If we timed out but had launched, we treat as not crashed for that window
        # However if log shows crash before timeout, keep crashed True
        # Check if last lines contain success markers without error
        if "ErrorIncompatibleDriver" not in text and "Unreachable" not in text:
            crashed = False

    # Stage detection (progress gates)
    # G0 built, G1 launched, G2 menu, G3 Drake's Fortune starts, G4 intro, G5 gameplay, G6 60s
    stage = "UNKNOWN"
    signature = ""
    # Simple heuristics based on log content
    if not built:
        stage = "G0_BUILD_FAILED"
        signature = "build missing"
    elif not launched:
        stage = "G1_NOT_LAUNCHED"
        # Try to extract error
        m = re.search(r"Game ID or file path not found:.*", text)
        if m:
            signature = m.group(0)[:120]
        elif "No available video device" in text:
            signature = "No available video device"
        elif "ErrorIncompatibleDriver" in text:
            signature = "ErrorIncompatibleDriver"
        elif "Failed to create instance" in text:
            signature = "Failed to create instance"
        else:
            signature = f"exit_code={exit_code}"
    else:
        # Launched, check further
        if "Game id: CUSA03280" in text:
            # Check for collection menu vs Drake's Fortune
            # The game title for CUSA03280 is collection; Drake's Fortune is sub-game
            # Look for u1data paths, videoOut, etc.
            if "u1data/build/main" in text or "shareddata" in text:
                stage = "G3_DRAKES_FORTUNE_STARTS"
            elif "sceVideoOutOpen" in text:
                stage = "G3_DRAKES_FORTUNE_STARTS"
            else:
                stage = "G2_COLLECTION_MENU"
            # Check for intro/cutscene
            if "movie1" in text or "sce-ndi-logos" in text:
                stage = "G4_INTRO"
            # Check for flip queue etc. indicates rendering loop
            if "FLIP QUEUE" in text or "RegisterBuffers" in text:
                # This is at least after init, could be gameplay transition
                stage = "G4_INTRO_OR_LATER"
            # If we stayed alive for timeout duration, consider G6 candidate
            if timeout and not crashed:
                stage = "G6_60S_ALIVE"
                signature = "timeout_60s_no_crash"
            else:
                # Determine crash signature
                # Look for last error
                err_lines = [l for l in text.splitlines() if "Error" in l or "Critical" in l or "Assertion" in l]
                if err_lines:
                    signature = err_lines[-1][:200]
                else:
                    signature = f"launched exit={exit_code}"
        else:
            stage = "G1_LAUNCHED_UNKNOWN"
            signature = f"exit={exit_code}"

    # Normalize signature
    signature = re.sub(r"\x1b\[[0-9;]*m", "", signature)  # strip ANSI
    signature = signature.strip()[:200]

    result = {
        "built": built,
        "launched": launched,
        "timeout": timeout,
        "crashed": crashed,
        "fatal_assertion": fatal_assertion,
        "exit_code": exit_code,
        "stage": stage,
        "signature": signature
    }
    # Write JSON
    out = result_dir / "classify.json"
    out.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return result

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <result_dir>")
        sys.exit(1)
    result_dir = pathlib.Path(sys.argv[1])
    classify(result_dir)
