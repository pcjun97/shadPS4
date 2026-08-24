# UC1 Findings – shadPS4 WSL2

## Baseline
- WSL: Ubuntu 22.04.5 LTS, kernel 6.18.33.2-microsoft-standard-WSL2, WSL 2.7.12
- Repo: `pcjun97/shadPS4` branch `main` @ `443676d8` (reduce sceImeDialogGetStatus)
- Compiler: `gcc-16` (Homebrew 16.1.0, glibc 2.39) – `clang 18` fails on `openal-soft` consteval (libstdc++11 ranges)
- Build: `RelWithDebInfo` via `Ninja`, `SDL_UNIX_CONSOLE_BUILD=ON`, `LIBUSB_ENABLE_UDEV=OFF`, X11/Wayland via `brew` (`libx11`, `wayland`, `libxcursor` etc.), `vulkan-loader 1.4.357` + `mesa-vulkan-drivers 23.2.1` lavapipe (`libvulkan_lvp.so` extracted to `tools/mesa/`)
- Game: `EP9000-CUSA03280_00-UNCHARTEDFORTUNE` (11G `uncharted1.pkg`) extracted via `shadPS4Plus/pkg_extractor` AppImage (`squashfs-root/usr/bin/pkg_extractor` via `brew` `ld.so`) to `games/CUSA03280` (15G, `eboot.bin` 9.9M) + `~/games` legacy
- Config: portable `./user/config.json` (`UserDir` = `current_path()/user` when `./user` exists, else `~/.local/share/shadPS4`), `install_dirs=[./games]`, `GPU.null_gpu=true` (headless), `Log.separate=true`
- Run: `VK_ICD_FILENAMES=tools/mesa/lvp_icd.json`, `LD_SO=/home/linuxbrew/.linuxbrew/lib/ld.so --library-path ...`

## Gates
- G0 build: PASS (610M `build/shadps4`)
- G1 launch: PASS (with `VK_ICD`+correct `LIBPATH` including `/lib/x86_64-linux-gnu` for `libLLVM-15`)
- G2 collection menu: UNTESTED
- G3 Drake's Fortune starts: PASS (log shows `Game id CUSA03280`, `eboot SDK 0x2508051`, `sceVideoOutOpen`, `RegisterBuffers`, `u1data/build/main/...`)
- G4 intro: PARTIAL (movies `sce-ndi-logos` seen, but need 60s validation)
- G5 transition: UNKNOWN
- G6 60s alive: TODO – need `run.sh` timeout 90s in `null` mode

## Hypotheses

### H001 – Build fails with clang 18 + libstdc++11
- Observation: `openal-soft/alc/alc.cpp:375` `ranges::transform` with `views::split` fails: `no matching function` + `consteval` not constant
- Hypothesis: `gcc-11` libstdc++ lacks C++23 `ranges` constexpr; `consteval` requires compile-time
- Evidence: `cmake` with `clang 18` + system `libstdc++11` → 5 errors; with `g++-16` libstdc++16 succeeds
- Change: `externals/openal-soft/alc/alc.cpp` `consteval` → `inline`, `static constexpr` → `static const` (2 sites); also set `LIBUSB_ENABLE_UDEV=OFF` to avoid `libudev.h` missing
- Result: Build succeeds with `g++-16` (2472 targets, ~40min). `clang 18` still fails.
- Decision: KEEP (temporary; upstream needs newer libstdc++ or patch)
- Commit: dirty in `externals/openal-soft` (not committed)
- What not to retry: `clang 18` without newer stdlib

### H002 – SDL “No available video device”
- Observation: `SDL_Init(SDL_INIT_VIDEO)` fails `No available video device` with `SDL_UNIX_CONSOLE_BUILD=ON` and without `VK_ICD`
- Hypothesis: `console` build disables X11/Wayland, `dummy` needs `SDL_VIDEODRIVER=dummy` or `VK_ICD` not set → `CreateInstance` fails earlier
- Evidence: Log `SDL_Init` critical, then `timeout: dumped core`
- Change: Ensure `VK_ICD_FILENAMES` + `LIBPATH` includes `/lib/x86_64-linux-gnu` for `libLLVM-15`; keep `SDL_UNIX_CONSOLE_BUILD=ON` (provides `dummy`+`offscreen`), window `Headless` works with `null_gpu`
- Result: With correct `VK_ICD`+`LIBPATH`, `SDL` init passes, `CreateInstance` succeeds via `lavapipe`, game boots
- Decision: KEEP
- What not to retry: `console` without `lavapipe` ICD

### H003 – Vulkan `ErrorIncompatibleDriver`
- Observation: `vkPlatform: Creating vulkan instance` → `Failed to create instance: ErrorIncompatibleDriver`, `Candidate instance extension VK_KHR_xlib_surface is not available`
- Hypothesis: No Vulkan ICD found (loader has no driver) → `enumerateInstanceExtensionProperties` empty, `libLLVM` missing from `ld.so` path
- Evidence: `vulkaninfo` without `VK_ICD` → `Found no drivers!`; with `VK_ICD=/tmp/mesa/.../lvp` + `ld.so --library-path /lib/x86_64-linux-gnu` → `llvmpipe` found, `apiVersion 1.3.255`
- Change: Extract `mesa-vulkan-drivers` deb to `tools/mesa` (or `/tmp/mesa`), create `tools/mesa/lvp_icd.json` pointing to `libvulkan_lvp.so`, set `VK_ICD_FILENAMES` in `run.sh`
- Result: `vulkaninfo` succeeds, shadPS4 `CreateInstance` succeeds, game proceeds past `Kernel.Vmm` to `sceVideoOut`
- Decision: KEEP
- What not to retry: `VK_ICD` pointing to non-existent or wrong `library_path`

## Next Hypothesis (TBD)
- Need to classify current run with `null` mode 90s timeout to determine G4-G6 stage and signature
- If G4 survives, test 60s `G6`; if crashes, inspect `shad_log.txt` for `fatal assertion`, `guest PC`, `signal`
