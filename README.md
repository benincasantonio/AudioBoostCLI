# AudioBoostCLI

A macOS audio booster with keyboard controls. Rust handles the CLI, terminal, and private Unix socket; a small Objective-C/C bridge connects a Core Audio process tap to the built-in output and Apple's peak limiter.

The MVP targets Apple Silicon, macOS 14.2 or later, built-in speakers, and wired headphones connected directly to the Mac's 3.5 mm jack. HDMI/DisplayPort outputs (including monitor-connected soundbars), Bluetooth, USB/Thunderbolt interfaces, and multichannel output are outside its scope. Additional output support is planned as a separate integration. Automatic loudness leveling, login startup, and notarized binary distribution are also outside this MVP.

This is an early source release. Automated checks and short live tests have passed on a Mac mini; the 30-minute stability run and several physical hardware checks remain incomplete. See the [acceptance record](docs/acceptance.md) for measured results and remaining checks.

## Install and run

Install Xcode or its command-line tools, Rustup, and Python 3, then:

```sh
git clone https://github.com/benincasantonio/AudioBoostCLI.git
cd AudioBoostCLI
make tools
make check
make install
```

Python is used for development tools, packaging, and integration tests. The installed CLI and background service run without Python.

The toolchain file pins Rust **1.90.0**, Rust 2024, rustfmt, and Clippy. `Cargo.lock` pins the application dependencies. `make tools` downloads checksum-verified official binaries for nextest **0.9.148**, cargo-audit **0.22.2**, and cargo-deny **0.20.2** into `.tools/bin`; it does not upgrade the application compiler.

`make install` creates an ad-hoc signed `~/Applications/AudioBoost.app` and links `~/.local/bin/audioboost` to its executable. Add `~/.local/bin` to your shell's PATH if necessary. The installer stops an earlier AudioBoost service before updating it and refuses to overwrite an unrelated app or command.

```sh
audioboost
```

On the first start, allow **AudioBoost** in the macOS system-audio recording prompt. Permission is under **System Settings → Privacy & Security → Screen & System Audio Recording**. A rebuild may require renewed permission. Audio stays in memory: the service neither saves recordings nor makes network requests.

| Command | Behavior |
|---|---|
| `audioboost` | Enable boosting and open keyboard controls; attach to an active service without changing its gain. |
| `audioboost start [--gain-db N]` | Start detached processing; a fresh start defaults to +3 dB. An already-active service keeps its gain. |
| `audioboost gain N` | Set a finite gain between 0 and 12 dB. |
| `audioboost status` | Show state, gain, device, sample rate, pipeline latency, callback counters, PID, and engine error. |
| `audioboost stop` | Stop the service and release playback interception. Safe to repeat. |

**↑ / →** add 1 dB; **↓ / ←** subtract 1 dB, clamped to 0–12 dB. **Q or Ctrl-C stops boosting**, even when attaching to an existing background service. The default command requires interactive stdin and stdout and checks this before starting audio. Use the scripting commands in pipes and automation.

Explicit background mode survives terminal closure. Gain is not persisted across service runs. Switching between supported default outputs resets gain to 0 dB. Format changes and waking from sleep rebuild the graph; unsupported outputs release interception and show an error.

## Audio and lifecycle

The private, device-specific tap excludes the service's Core Audio process object. Its `mutedWhenTapped` setting intercepts original playback only while the aggregate reads the tap. The private aggregate uses the physical output as its clock source. A permission probe precedes interception, and failed starts and render errors tear down the graph.

The native path accepts Float32 stereo at the output's current rate. Gain changes ramp over 20 ms. Apple's peak limiter uses a 5 ms attack and 50 ms release. A compensated +1 dB pre-scale and −1 dB post-scale set a −1 dBFS sample-peak ceiling while preserving requested gain below limiting. This is sample-peak limiting, not true-peak or loudness normalization.

Buffers are allocated before processing. The callback has no application allocation, locks, logging, or IPC. A private aggregate buffer of at most 256 frames limits delay; if configuring it changes the physical device's buffer size, normal teardown restores the previous size unless another client has since changed it. Core Audio and IOKit notifications handle device changes and sleep/wake. Control operations and cleanup stay on one thread; the audio thread exchanges only lock-free atomic values and preallocated samples.

The socket lives in a mode-0700 per-user temporary directory and is mode 0600. Both ends verify peer ownership. Messages are newline-delimited JSON with a 4096-byte bound and timeouts. A retained file lock prevents concurrent service owners; stale sockets are recovered on restart. `AUDIOBOOST_RUNTIME_DIR` isolates test services; normal LaunchServices launches use the default location.

## Verification

`make check` runs these commands through RTK when installed, and runs the same Cargo checks directly otherwise:

```sh
rtk cargo fmt --all -- --check
rtk cargo clippy --locked --all-targets --all-features -- -D warnings
rtk cargo nextest run --locked --all-targets --all-features
rtk cargo test --locked --doc --all-features
rtk cargo audit
rtk cargo deny check
```

It then builds the debug CLI and runs the Python pseudo-terminal and real-service lifecycle tests. Doctests remain separate because [nextest does not run them](https://nexte.st/docs/running/). Advisory downloads are required; unavailable databases or failed checks are failures. License allowances cover the current permissive dependencies, unapproved sources are denied, and duplicate versions generate warnings.

Normal tests never intercept or play system audio. They cover argument validation, gain bounds, IPC framing and ownership, keyboard controls, polling/redraw behavior, terminal restoration, resize, concurrent services, disconnected clients, and restart after termination. Native offline tests exercise 44.1/48 kHz gain, the complete smoothing ramp, stereo, silence, transients, sustained limiting, and the output ceiling.

```sh
make native-asan
cargo +nightly-2026-10-19 miri test --locked --lib
```

ASan/UBSan test native sample buffers and repeated engine lifetimes without capture. Miri uses a separate pinned nightly and tests the Rust-only model; it cannot verify the Core Audio FFI. On macOS 26.6.2, this machine's Xcode Clang 17 sanitizer deadlocked before `main`; the already-installed Command Line Tools Clang 21 passes:

```sh
CC=/Library/Developer/CommandLineTools/usr/bin/clang make native-asan
```

The macOS CI workflow runs the full verification command, native sanitizers, a release bundle build, and Miri. CI does not replace physical hardware and listening acceptance.

## Explicit hardware checks

These commands intercept playback. They run serially using a separate lock, require the installed app, refuse to take over an existing service, and stop their service on normal completion and handled interruption.

```sh
audioboost stop
python3 scripts/hardware-test.py --force-termination
python3 scripts/hardware-test.py --sample-rates
python3 scripts/benchmark.py --seconds 1800 --with-ui --gain-db 3
```

The format test temporarily selects 44.1 and 48 kHz and restores the original rate. The benchmark measures cumulative process CPU time and combined RSS, includes the interface, requires progressing callbacks without faults, and writes a JSON result under `target/acceptance/`. Its limits are CPU **<2% of one core**, RSS **<50 MiB**, and reported pipeline latency **≤20 ms**. Run it with real playback, then repeat without `--with-ui` to isolate background mode.

The latency report includes the Core Audio input/output timestamp difference and the Audio Unit's reported limiter delay. It is not an independent physical measurement of added latency; the acceptance procedure covers that distinction. Headphone changes, sleep/wake, permission denial, and listening comparisons also need the explicit procedures in [docs/acceptance.md](docs/acceptance.md).

## Implementation references

- [Apple: capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Crossterm](https://docs.rs/crossterm/0.29.0/crossterm/)
- [Nextest toolchain compatibility](https://nexte.st/docs/stability/)
- [Chromium's public tap-description permission probe](https://chromium.googlesource.com/chromium/src/+/7de33fdc657509ffda089a858e0ea9c231547fbe/media/audio/mac/catap_audio_input_stream.mm)

The seven global clean-code skills come from `benincasantonio/clean-code-skills` revision `031dc0387b47846aea7cba3cf46365a3c6ea64d2`, and the complete `leonardomso/rust-skills` package from `fd2a861ab0406a4ac536a55274d14ea6fd1ca9c9`. They are development guidance, not runtime dependencies.
