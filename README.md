# programs.clashix 🚀

[💡 中文版说明文档 (Chinese README)](README_zh.md)

A declarative, headless Mihomo (Clash Meta) client module for NixOS and Home Manager, complete with an integrated standalone web dashboard (Yacd, Metacubexd, or Zashboard).

## Features

- **Fully Declarative**: Manage your core proxies, ports, and modes natively through Nix options.
- **Multiple Subscriptions**: Feed in a list of URLs and let the systemd timers securely fetch and merge them automatically.
- **Micro Dashboard Server**: The chosen web UI is served by isolated `darkhttpd` systemd services, reducing dependencies and keeping the Mihomo core strict.
- **TUN Mode Ready**: First-class support for transparent proxy environments.

## Installation & Usage

### 1. NixOS with Flakes (Recommended)

Add `clashix` to your `flake.nix` inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    clashix.url = "github:DawnMagnet/clashix";
  };

  outputs = { self, nixpkgs, clashix, ... }: {
    nixosConfigurations.myHost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        clashix.nixosModules.clashix
        ./configuration.nix
      ];
    };
  };
}
```

In your `configuration.nix`:

```nix
programs.clashix = {
  enable = true;

  # Core network bindings
  port = 7890;
  socksPort = 7891;
  mixedPort = 7892;
  allowLan = true;
  mode = "Rule";

  # Dashboard configuration (Served independently)
  dashboard = {
    enable = true;
    type = "yacd"; # Options: "none", "yacd", "metacubexd", "zashboard"
    port = 8080;
    bindAddress = "0.0.0.0";
  };

  # Subscriptions
  subscriptionUrls = [
    "https://your.sub.link/1"
    "https://your.sub.link/2"
  ];
  updateInterval = "daily";

  # Provide additional vanilla YAML configs to merge
  extraConfig = {
    ipv6 = false;
  };
};
```

### 2. Home Manager with Flakes

Similarly, import it from `flake.nix` and pass it to your Home Manager configuration:

```nix
modules = [
  clashix.homeManagerModules.clashix
  ./home.nix
]
```

Configuration syntax inside `home.nix` is identical to NixOS. The services will be run as systemd *user* services.

*Note on TUN Mode*: Under standalone Home Manager (non-NixOS), your user service does not possess network capabilities (`CAP_NET_ADMIN`). To enable TUN mode seamlessly, you can grant capabilities to a local copy of the binary:

1. Copy the binary and grant capabilities (run once):
   ```bash
   mkdir -p ~/.local/bin
   cp $(readlink -f $(which mihomo)) ~/.local/bin/mihomo-cap
   sudo setcap 'cap_net_admin,cap_net_bind_service=+ep' ~/.local/bin/mihomo-cap
   ```

2. Configure Clashix to use this binary in your `home.nix`:
   ```nix
   programs.clashix = {
     enable = true;
     tun.enable = true;
     package = pkgs.writeShellScriptBin "mihomo" ''
       exec ~/.local/bin/mihomo-cap "$@"
     '';
     # ... rest of config
   };
   ```

### 3. NixOS without Flakes (Legacy)

You can import the module directly by downloading the source archive:

```nix
{ config, pkgs, ... }:
let
  clashix = fetchTarball "https://github.com/yourname/clashix/archive/main.tar.gz";
in
{
  imports = [ "${clashix}/modules/nixos" ];
  programs.clashix.enable = true;
  # ... rest of config
}
```

### 4. Home Manager without Flakes

```nix
{ config, pkgs, ... }:
let
  clashix = fetchTarball "https://github.com/yourname/clashix/archive/main.tar.gz";
in
{
  imports = [ "${clashix}/modules/home-manager" ];
  programs.clashix.enable = true;
}
```
