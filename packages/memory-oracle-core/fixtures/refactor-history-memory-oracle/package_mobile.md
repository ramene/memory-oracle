---
name: PACKAGES-MOBILE
description: The mobile package — React Native demo for patient consent flow.
metadata:
  type: package
  authored_at: 2026-05-20T10:00:00Z
  package_path: packages/mobile
  package_name: "@memory-oracle/mobile"
---

# packages/mobile — patient mobile demo package

The mobile package contains the React Native demo for the patient
consent flow: QR code generation, encounter relay polling, Face ID
gate, encryption with operator-specific age recipients.

Layout:
- `packages/mobile/index.js` — entry point
- `packages/mobile/package.json` — name `@memory-oracle/mobile`
- `packages/mobile/demo/generate-patient-qr.html` — QR generator
- `packages/mobile/demo/unlock-patient.sh` — unlock script

Imports across the monorepo reference `@memory-oracle/mobile`.
