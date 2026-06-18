# Changelog

## 1.1.4 - 2026-06-19

### Fixed

- Only reload or restart `clashix.service` after successful subscription updates; failed updates no longer trigger Mihomo reloads.
- Restart Mihomo instead of reloading it after successful subscription updates when TUN mode is enabled.

## 1.1.3 - 2026-06-19

### Fixed

- Add a periodic TUN health check that restarts `clashix.service` when the TUN interface or its default route disappears after startup.

## 1.1.2 - 2026-05-19

### Fixed

- Keep `/var/lib/clashix/config.yaml` owned by the `clashix` system user after startup and subscription updates, preventing permission-related daemon start failures.

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
