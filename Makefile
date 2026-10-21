.PHONY: tools check build install test native-asan hardware-test benchmark

tools:
	python3 scripts/install-tools.py

check:
	bash scripts/check.sh

build:
	cargo build --release --locked
	python3 scripts/package.py

install: build
	python3 scripts/package.py --install

test:
	cargo test --locked --all-targets
	python3 tests/terminal_test.py
	python3 tests/service_test.py
	python3 tests/hardware_tools_test.py

native-asan:
	bash scripts/native-asan.sh

hardware-test:
	python3 scripts/hardware-test.py

benchmark:
	python3 scripts/benchmark.py --seconds 1800
