# Changelog

## 1.1.1 - 2026-05-12

### Added

- Add a TUN startup safety gate that validates the active Mihomo config before route takeover.
- Refuse first TUN startup when no existing config or `bootstrapConfig` is available.
- Add configurable TUN safety fallback behavior via `programs.clashix.tun.safety`.
- Add regression coverage for first-start TUN refusal, normal TUN startup, and gVisor TUN startup.

### Changed

- Validate downloaded subscription configs before replacing the active runtime config.
- Keep the last known good config metadata after successful subscription updates.
- Detect the current Mihomo `Meta` TUN interface in addition to `utun` and `tun0`.

