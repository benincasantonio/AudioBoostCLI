# Acceptance record and remaining hardware checks

Test host: Apple Silicon Mac mini, macOS 26.6.2. Rust 1.90.0. Local ad-hoc signed app launched through LaunchServices. Run date: 21 October 2026, Europe/Rome.

## External-output integration

The updated engine supports compatible built-in, HDMI/DisplayPort, USB, and Bluetooth/Bluetooth LE stereo outputs. Both terminal interfaces show reported pipeline latency and the latest playback buffer in frames and milliseconds. Results below apply to this integration; the original MVP record is retained separately.

| Check | Result |
|---|---|
| Full `make check` | Passed: formatting, Clippy, 16 nextest tests, doctests, refreshed advisory/license checks, 8 PTY tests, 3 service tests, 3 acceptance-policy tests |
| Native ASan/UBSan | Passed using Command Line Tools Clang 21, including maximum frame capacity, duplex routing, unsupported modes, reconnect, retry limits, permission failures, and teardown failures |
| Miri | 7 Rust model tests passed with nightly-2026-10-19 |
| Final release build and local signing | Passed; updated app installed locally |
| Bluetooth smoke: HUAWEI FreeBuds 5i | Passed repeated start/stop and forced service termination at 0 dB |
| Bluetooth continuous playback, before final recovery refinements | At +3 dB: 44.1 kHz, 256 frames (5.8 ms), 16.61 ms reported latency, no callback faults in the first 203 seconds; about 0.56% of one core and 25.73 MiB peak combined RSS |
| Bluetooth listening | User reported dropping audio at the beginning of the checks, followed by good playback. Cause of startup drops not established; deliberate lifecycle checks also ran at the beginning |
| Final-build live route switching | Passed: LG HDR 4K soundbar path, Sony Wireless Stereo Headset over USB, AUNA MIC-920 duplex USB output, built-in speakers, and HUAWEI FreeBuds 5i. Every switch reset gain to 0 dB; callbacks progressed with zero faults |
| Final-build reported measurements | All routes used 256 frames. At 48 kHz: LG 22.33 ms, Sony/AUNA 18.25 ms, built-in 17.17 ms. FreeBuds at 44.1 kHz: 16.61 ms. These are pipeline reports, not acoustic measurements |
| Unsupported-output transition and recovery | Passed: Steam Streaming Speakers released interception and cleared measurements; returning to FreeBuds resumed stereo at 0 dB |
| 30-minute stability | Incomplete: initial Bluetooth service/socket disappeared after approximately 3 minutes. macOS recorded a clean exit; user was unsure whether they stopped the shared service. Cause remains unconfirmed. No completed 30-minute integration run on any route |
| Remaining physical checks | Paused at the user's request: sustained stability, disconnect/reconnect, Bluetooth microphone/call-mode transitions, sleep/wake, full stereo/feedback/listening comparisons, and external sample-rate changes. Offline recovery tests passed; these do not replace physical checks |
| Physical added latency | Not independently measured; reported latency does not measure the complete Bluetooth acoustic path |

The final-build route measurements are recorded in `target/acceptance/route-smoke.json` (local, untracked). No live audio test is left running. Permission-denial checks on physical hardware remain pending; permission failure handling is covered offline.

## Original MVP results

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
2. **Output switching:** start at +3 dB on speakers. Select the monitor/soundbar, USB wireless headset, and Bluetooth stereo output in macOS in turn. Confirm the displayed device changes, gain resets to 0 dB, fresh latency and buffer values appear, and playback continues. Repeat wired-headphone plug/unplug and external-device disconnect/reconnect. On a duplex device, confirm microphone input is never played through the boost path. Select a virtual or multichannel output and verify interception is released; return to supported stereo and confirm automatic recovery at 0 dB.
3. **Sleep/wake:** start playback and boosting, put the Mac to sleep, then wake it. Confirm a rebuilt active graph, progressing callback count, unchanged gain on the same output, and no persistent silence. If the output changed while sleeping, gain must be 0 dB. Stop and confirm ordinary playback.
4. **Feedback exclusion:** play a short signal or recording at +3 dB, then stop the source. The output must decay to silence, without repeating or increasing echoes. Repeat gain changes while playing independent left/right content; confirm stereo placement remains intact.
5. **Listening:** compare a quiet recording at 0, +3, and +6 dB. Repeat with already-loud, transient-heavy material. Quiet material should gain useful level; loud material may gain less because the limiter protects the ceiling. Reject audible clicks during changes, pumping, harsh distortion, channel collapse, or interruptions. Record the material and listener's result without recording captured system audio.
6. **Stability:** run `python3 scripts/benchmark.py --seconds 1800 --with-ui --gain-db 3` with real playback on each supported hardware route. The report must show no callback faults or stalls, average CPU below 2% of one core, and maximum sampled combined RSS below 50 MiB. Built-in outputs require reported latency at most 20 ms; external latency is recorded without a default ceiling. Use `--max-latency-ms N` for an explicit external threshold. Keep the same device and sample rate throughout each run. Record audible gaps separately. Reports contain device UID, transport, observed frame-count bounds, and the tested executable's SHA-256.
7. **Physical latency:** compare the timing of the same transient with boosting stopped and active through the same built-in or wired output. Measure with an independent timing/loopback setup and subtract the baseline device path; include all buffering and limiter delay. Require added latency at most 20 ms at both 44.1 and 48 kHz. Core Audio timestamps alone cannot certify this result. External measurement equipment is a test fixture, not an additional supported playback device.
8. **Bluetooth call mode:** while boosting stereo playback, open an app that uses the headset microphone. If the route becomes mono or otherwise unsupported, confirm boosting suspends, measurements become unavailable, and ordinary playback continues. Release the microphone and confirm stereo boosting resumes at 0 dB without restarting AudioBoost. Keep the default macOS input unchanged after the test.

## Regression history

Behavioral tests exposed and fixed an unused IPC connection that delayed shutdown, a disconnected-client error that terminated the service, and unnecessary redraws at gain boundaries. The offline ramp check now counts the full 20 ms transition, including the limiter's delayed output, rather than inspecting only the first block.

A failed interactive start now shuts down its service before exiting. Its regression test first failed because no stop request was sent, then passed with the cleanup in place; this prevents an output change from enabling audio after the interface has already exited.

Native callback tests additionally verify that short input buffers are rejected and hardware output is silenced on processing errors. The production cleanup retains callback-owned memory if HAL refuses to release it and exits the service so the operating system can release interception.
