#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/.tools/bin:$PATH"
for tool in cargo-nextest cargo-audit cargo-deny; do
    test -x ".tools/bin/$tool" || { echo "Missing pinned $tool; run make tools" >&2; exit 1; }
done
# RTK only filters output. CI can run the identical Cargo checks without it.
if command -v rtk >/dev/null; then runner=(rtk cargo); else runner=(cargo); fi
"${runner[@]}" fmt --all -- --check
"${runner[@]}" clippy --locked --all-targets --all-features -- -D warnings
"${runner[@]}" nextest run --locked --all-targets --all-features
"${runner[@]}" test --locked --doc --all-features
"${runner[@]}" audit
"${runner[@]}" deny check
"${runner[@]}" build --locked
python3 tests/terminal_test.py
python3 tests/service_test.py
