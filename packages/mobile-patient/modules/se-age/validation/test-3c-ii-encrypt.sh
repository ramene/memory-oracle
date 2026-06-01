#!/bin/bash
# Mac-side validation of 3c-ii: age v1 encryption Swift implementation.
#
# Test A: our-encrypt → our-decrypt roundtrip (uses non-SE CryptoKit keys
#         on both sides; no Touch ID needed; fully automated).
# Test B: our-encrypt to the operator's Sequoia verum --se recipient
#         (writes /tmp/3cii-to-sequoia.age — operator runs the actual
#          age -d at the Sequoia GUI console because Touch ID can't fire
#          over SSH).
#
# Requires:
#   - Swift 5.4+
#   - Optionally: ~/verum-se-test/verum-se-identity.txt for Test B (the
#     script gracefully skips Test B if absent)
#
# Usage:
#   ./test-3c-ii-encrypt.sh
#
# Exits 0 on Test A pass; Test B is informational (operator runs the
# decrypt step manually at console).

set -euo pipefail
cd "$(dirname "$0")"

cat \
  ../ios/Bech32.swift \
  ../ios/AgeFile.swift \
  ../ios/AgeCrypto.swift \
  test-3c-ii-encrypt.swift \
  ../ios/AgeEncryptor.swift \
  > .combined.swift

trap 'rm -f .combined.swift' EXIT

swift .combined.swift
