## What this changes

<!-- One or two sentences. -->

## Checklist

- [ ] `./gxr doctor` passes
- [ ] `./tools/selftest.sh` passes
- [ ] If this adds or changes a demo, I ran it end to end and updated `last_verified`
- [ ] The README's manual steps still match the scripts
- [ ] `teardown.sh` drops only the demo's database — it does not touch the container or the volume
- [ ] `OMNI_VERSION` is still pinned; if I bumped it, I re-ran every demo
- [ ] Nothing here implies Kineviz's native Spanner connector reaches a Spanner Omni endpoint
- [ ] No credentials, no customer data, no gated artifacts
- [ ] The "formerly GraphXR" note is present on any new README

## Verified with

<!-- e.g. Spanner Omni 2026.r1-beta.2, Kineviz Desktop v0.17.1, macOS 15 (Apple Silicon), Docker Desktop 28.0.1 -->
