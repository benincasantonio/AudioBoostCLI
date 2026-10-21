# Acceptance record and remaining hardware checks

Test host: Apple Silicon Mac mini, macOS 26.6.2. Rust 1.90.0. Local ad-hoc signed app launched through LaunchServices. Run date: 21 October 2026, Europe/Rome.

## Recorded results

| Check | Result |
|---|---|
| rustfmt, Clippy with denied warnings | Passed |
| nextest | 13 tests passed, including native offline DSP |
| doctests | Passed; no doctests currently defined |
| cargo-audit, cargo-deny | Passed using refreshed advisory data; no suppressed findings |
| Pseudo-terminal integration | 6 tests passed: arrows/bounds, attach, Q/Ctrl-C, SIGTERM, failed-start and terminal-error cleanup, resize, polling/redraw |
| Real service, without capture | 3 tests passed: concurrent owners, malformed/disconnected clients, repeated and forced restart |
| Native ASan/UBSan | Passed with installed Apple Clang 21 |
| Miri | 6 Rust-only tests passed with nightly-2026-10-19 |
| Release build and local signing | Passed |
| Live speakers at 48 kHz | Active callbacks, no faults; 17.17 ms reported pipeline latency |
| Live 44.1/48 kHz format changes | Passed; original 48 kHz rate restored |
| Live repeated start/stop and forced service termination | Passed; replacement service progresses without faults |
| Short resource run, interface open | 15.08 s, 0.464% of one core, 24.31 MiB combined RSS, 17.167 ms reported latency |
| 30-minute stability and resource run | Two incomplete attempts: output changed first to Wireless Stereo Headset and then to LG HDR 4K; no completed 30-minute result |
| Unsupported-output transition | Both transitions released interception, reset gain to 0 dB, and reported the unsupported output; no callback faults |
| Quiet/loud listening comparison | User reports that a low-volume trial seems to work; fuller quiet/loud listening comparison deferred by the user |
| Physical added latency ≤20 ms | Not independently measured |
| Wired headphone transitions | Not yet exercised on this host |
| Sleep/wake with playback | Implemented; physical sleep/wake test pending |
| Explicit permission denial | Permission guard implemented; denial test pending |
| Remote macOS CI | Passed on GitHub's macOS runner: verification, native ASan/UBSan, release build, and Miri ([initial public run](https://github.com/benincasantonio/AudioBoostCLI/actions/runs/39552736886), commit `c82334f`) |

The initial live latency check failed at 27.83 ms. Configuring the private aggregate for at most 256 frames reduced the measured timestamp-plus-limiter delay to 17.17 ms, and the live regression then passed. A first unanswered macOS permission prompt caused a Core Audio timeout; after authorization, live start succeeded.

## Repeatable physical checks

Run these one at a time. Start from `audioboost stop`; use familiar material and a comfortable system volume. Do not alter output or sample rate during the fixed-format stability benchmark.

1. **Permission denial:** use System Settings to revoke AudioBoost's system-audio access. Run `python3 scripts/hardware-test.py --expect-permission-denial`, deny any prompt, and verify ordinary playback remains audible. Re-enable permission before other tests. Do not reset unrelated applications' permissions.
2. **Speakers and wired headphones:** start at +3 dB on speakers. Plug in wired headphones and select them as the default output if macOS does not. Confirm the displayed device changes, gain resets to 0 dB, and playback continues. Repeat unplugging headphones. Switch to an unsupported Bluetooth/USB output and verify interception is released and an unsupported-output error appears; return to built-in output and confirm gain 0 dB.
3. **Sleep/wake:** start playback and boosting, put the Mac to sleep, then wake it. Confirm a rebuilt active graph, progressing callback count, unchanged gain on the same output, and no persistent silence. If the output changed while sleeping, gain must be 0 dB. Stop and confirm ordinary playback.
4. **Feedback exclusion:** play a short signal or recording at +3 dB, then stop the source. The output must decay to silence, without repeating or increasing echoes. Repeat gain changes while playing independent left/right content; confirm stereo placement remains intact.
5. **Listening:** compare a quiet recording at 0, +3, and +6 dB. Repeat with already-loud, transient-heavy material. Quiet material should gain useful level; loud material may gain less because the limiter protects the ceiling. Reject audible clicks during changes, pumping, harsh distortion, channel collapse, or interruptions. Record the material and listener's result without recording captured system audio.
6. **Stability:** run `python3 scripts/benchmark.py --seconds 1800 --with-ui --gain-db 3` with real playback. The report must show no callback faults or stalls, average CPU below 2% of one core, maximum sampled combined RSS below 50 MiB, and reported pipeline latency at most 20 ms. Record any audible gaps separately. Reports contain the tested executable's SHA-256.
7. **Physical latency:** compare the timing of the same transient with boosting stopped and active through the same built-in or wired output. Measure with an independent timing/loopback setup and subtract the baseline device path; include all buffering and limiter delay. Require added latency at most 20 ms at both 44.1 and 48 kHz. Core Audio timestamps alone cannot certify this result. External measurement equipment is a test fixture, not an additional supported playback device.

## Regression history

Behavioral tests exposed and fixed an unused IPC connection that delayed shutdown, a disconnected-client error that terminated the service, and unnecessary redraws at gain boundaries. The offline ramp check now counts the full 20 ms transition, including the limiter's delayed output, rather than inspecting only the first block.

A failed interactive start now shuts down its service before exiting. Its regression test first failed because no stop request was sent, then passed with the cleanup in place; this prevents an output change from enabling audio after the interface has already exited.

Native callback tests additionally verify that short input buffers are rejected and hardware output is silenced on processing errors. The production cleanup retains callback-owned memory if HAL refuses to release it and exits the service so the operating system can release interception.
