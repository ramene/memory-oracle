# memory-oracle Go CLIs — single static binaries, zero CGO.
# Cross-compiles to darwin/linux/windows × amd64/arm64.

BIN_DIR := $(HOME)/.bin
LDFLAGS := -s -w
VERSION := 0.1.0

.PHONY: all build install clean test cross

all: build

build:
	go build -ldflags="$(LDFLAGS)" -o memory-search.bin ./cmd/memory-search
	go build -ldflags="$(LDFLAGS)" -o memory-cite.bin ./cmd/memory-cite

install: build
	install -m 0755 memory-search.bin $(BIN_DIR)/memory-search-go
	install -m 0755 memory-cite.bin $(BIN_DIR)/memory-cite-go
	@echo "installed to $(BIN_DIR)/memory-search-go and memory-cite-go"

clean:
	rm -f memory-search.bin memory-cite.bin
	rm -rf dist/

test: build
	./memory-search.bin "supersession sidecar" --budget=4000 --k=2
	@echo "---"
	@if [ -n "$$TEST_SESSION" ]; then ./memory-cite.bin --session $$TEST_SESSION --info; fi

# Cross-compile for distribution. Pure-Go (modernc.org/sqlite) so no CGO required.
cross:
	mkdir -p dist
	@for OS in darwin linux windows; do \
	  for ARCH in amd64 arm64; do \
	    EXT=""; [ $$OS = windows ] && EXT=".exe"; \
	    echo "build $$OS/$$ARCH..."; \
	    GOOS=$$OS GOARCH=$$ARCH go build -ldflags="$(LDFLAGS)" -o dist/memory-search-$$OS-$$ARCH$$EXT ./cmd/memory-search; \
	    GOOS=$$OS GOARCH=$$ARCH go build -ldflags="$(LDFLAGS)" -o dist/memory-cite-$$OS-$$ARCH$$EXT ./cmd/memory-cite; \
	  done \
	done
	@ls -lh dist/
