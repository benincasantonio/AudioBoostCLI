#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p target/native
flags=(-Wall -Wextra -Werror -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -mmacosx-version-min=14.2 -isysroot "$(xcrun --show-sdk-path)")
compiler="${CC:-$(xcrun --find clang)}"
"$compiler" -std=c11 "${flags[@]}" native/processor.c native/processor_test.c -framework AudioToolbox -o target/native/processor-asan
python3 -c 'import subprocess; subprocess.run(["target/native/processor-asan"], check=True, timeout=30)'
"$compiler" -std=c11 -fobjc-arc "${flags[@]}" native/processor.c native/engine_test.m -framework AudioToolbox -framework CoreAudio -framework Foundation -framework IOKit -o target/native/engine-asan
python3 -c 'import subprocess; subprocess.run(["target/native/engine-asan"], check=True, timeout=30)'
