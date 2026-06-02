#!/bin/bash
# Mac-side validation of 3c-i: age v1 decryption Swift implementation.
#
# Encrypts a known plaintext via the official `age` CLI (which spawns
# `age-plugin-se` to wrap to an `age1se1...` recipient), then decrypts
# using AgeFile.swift + AgeCrypto.swift exactly as they live in the
# Expo native module. Plaintext must roundtrip.
#
# Requires:
#   - age binary at $HOME/.local/bin/age (or in PATH)
#   - age-plugin-se binary at $HOME/.local/bin/age-plugin-se
#   - Swift 5.4+ (any modern Xcode CLT works)
#   - macOS — no iPhone needed for this validation
#
# Usage:
#   export PATH=$HOME/.local/bin:$PATH
#   ./test-3c-i-decrypt.sh
#
# Exits 0 on roundtrip success, 1 on any failure.

set -euo pipefail

cd "$(dirname "$0")"

# Concatenate the three source files in dependency order, then append the
# test driver. Bech32 has no deps; AgeFile depends on Bech32-free
# Foundation only; AgeCrypto depends on Foundation + CryptoKit and uses
# AgeHeader from AgeFile.swift.
cat \
  ../ios/Bech32.swift \
  ../ios/AgeFile.swift \
  ../ios/AgeCrypto.swift \
  test-3c-i-decrypt.swift \
  > .combined.swift

trap 'rm -f .combined.swift' EXIT

swift .combined.swift
