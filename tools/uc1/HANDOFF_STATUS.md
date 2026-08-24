Current shadPS4 commit: 443676d8 (reduce sceImeDialogGetStatus to trace) - dirty (openal-soft consteval patch, build artifacts)
WSL distro/kernel: Ubuntu 22.04.5 LTS / 6.18.33.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun 18 21:54:43 UTC 2026 x86_64 / WSL 2.7.12.0
Compiler/build configuration: gcc-16 (Homebrew 16.1.0, glibc 2.39) / RelWithDebInfo / Ninja / -DSDL_UNIX_CONSOLE_BUILD=ON -DLIBUSB_ENABLE_UDEV=OFF -DCMAKE_PREFIX_PATH=/home/linuxbrew/.linuxbrew / Vulkan lavapipe via mesa-vulkan-drivers 23.2.1 (libvulkan_lvp.so) + vulkan-loader 1.4.357
Game build/version identifier if discoverable without exposing sensitive data: CUSA03280 EP9000-CUSA03280_00-UNCHARTEDFORTUNE App Ver 01.00 FW 0x4000000 SDK 0x2508000/0x2508051 - Title: Uncharted™: Drake's Fortune Remastered (Nathan Drake Collection)

Highest gate reached: G6 (guest/emulator remains alive >=60s after gameplay begins) in null/core path – reproducible 60s and 90s timeouts
Current failure signature: timeout_60s_no_crash (no crash, clean timeout after 60/90s, logs show steady PlayGo polling, no fatal assertion)
Reproduction command: VK_ICD_FILENAMES=tools/mesa/lvp_icd.json LD_LIBRARY_PATH=... /home/linuxbrew/.linuxbrew/lib/ld.so --library-path ... ./build/shadps4 CUSA03280  – or via harness: ./tools/uc1/run.sh null 60 CUSA03280 (also 90)
Expected reproduction time: 60-90s (timeout). Immediate launch <5s to G3.

Accepted commits: None yet (local dirty: externals/openal-soft consteval→inline patch for gcc-16 build; no emulator-core logic change needed for G6)
Key disproven hypotheses:
- H001 clang 18 + libstdc++11 ranges consteval – disproven, needs gcc-16 + patch, not a game bug
- H002 SDL No available video device – disproven, needed VK_ICD+correct LD path, not SDL dummy
- H003 ErrorIncompatibleDriver – disproven, needed lavapipe ICD with /lib/x86_64-linux-gnu in ld.so path, not driver bug

Important instrumentation added: None (existing logs sufficient: Game id, eboot SDK, Kernel.Vmm, sceVideoOutOpen/RegisterBuffers, PlayGo polling, UpdatePlayTime). Classify.py uses those for stage.

Why work stopped: Success – G6 achieved reproducibly in null/core path (handover stop condition 1). Next gates are WSL-specific or Vulkan/driver correctness (G7) which is non-authoritative under WSL per WSL-specific rules.

Recommended next experiment: Validate native Linux (non-WSL) with real GPU driver (RADV/AMDGPU) and X11/Wayland SDL (rebuild without SDL_UNIX_CONSOLE_BUILD, use system Vulkan), run `./tools/uc1/run.sh vulkan 90 CUSA03280` to check G7 visible output. Also test 120s+ and observe intro→gameplay transition with renderdoc disabled. Check `user/log/CUSA03280.log` for `FLIP QUEUE`, `RegisterBuffers` and frame pacing.

Whether native Linux is now required: Yes – for G7 (Vulkan visible output) and for final validation of VM/signal/JIT edge cases. WSL is authoritative for null/core but provisional for Vulkan. Recommend handoff to native Linux before performance work.

Working tree: dirty `externals/openal-soft/alc/alc.cpp` (consteval patch), `user/config.json` (portable), `games/CUSA03280` (15G extracted), `tools/mesa/`, `tools/uc1/results/` – all expected. Main repo has untracked `handover.md`, `uncharted1.pkg`, `mesa-vulkan-drivers*.deb`, `squashfs-root/`.

Harness: `tools/uc1/run.sh` (null/vulkan, timeout, LD+VK_ICD, incremental build, per-game log capture), `tools/uc1/classify.py` (JSON with built/launched/timeout/crashed/stage/signature), `tools/uc1/findings.md`, `tools/uc1/state.json` created. Use `VK_ICD_FILENAMES=tools/mesa/lvp_icd.json` and `ld.so` wrapper for WSL.

