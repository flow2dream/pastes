.PHONY: build run release distribution package test

SWIFT_BIN_DIR := $(shell dirname "$$(xcrun --find swiftc)")
TESTING_PLUGIN := $(SWIFT_BIN_DIR)/../lib/swift/host/plugins/testing/libTestingMacros.dylib

build:
	./scripts/build.sh

run:
	./scripts/run.sh

release:
	./scripts/build.sh release

distribution:
	./scripts/build.sh release production

package:
	./scripts/package-release.sh

test:
	xcrun swift test --disable-xctest --enable-swift-testing \
		-Xswiftc -load-plugin-library -Xswiftc "$(TESTING_PLUGIN)"
