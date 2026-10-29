# IPTVX AetherEngine fork

- Preserve the complete requested upstream release and the existing IPTVX fork
  contracts, including iOS/tvOS 16 and compatible binary dependency pins.
- Before merging upstream or publishing an IPTVX tag, read
  [IPTVX fork maintenance](docs/iptvx-fork-maintenance.md).
- Every upstream upgrade must check, port where required, and apply the active
  patches through `bash Scripts/apply-iptvx-patches.sh --check` / `--apply`, then
  pass the registry's behavioral regressions. Never silently omit a patch that
  conflicts with changed upstream code.
- Retire a patch only after the upstream core demonstrably implements equivalent
  behavior and the same regressions pass without it. Record the upstream commit
  and verification in the registry.
- Use FlowDeck for Apple build/test/run/device operations. Keep source, automated
  test, simulator, macOS and physical-device evidence distinct.
- Do not move published tags, add host UI/settings workarounds or expose source
  URLs, credentials or headers in documentation and test evidence.
