# programs.clashix 🚀

[💡 中文版说明文档 (Chinese README)](README_zh.md)

A declarative, headless Mihomo (Clash Meta) client module for NixOS and Home Manager, complete with an integrated standalone web dashboard (Yacd, Metacubexd, or Zashboard).

## Features

- **Fully Declarative**: Manage core ports, modes, and network settings through Nix options. All Nix-controlled settings are automatically re-applied on every service restart via generation tracking — no manual config edits needed after a `nixos-rebuild`.
- **Multiple Subscriptions with Smart Merging**: Feed in a list of URLs. The first URL's config is used as the primary (proxy-groups, rules, etc.); subsequent URLs contribute only their proxies, avoiding duplicate proxy-group errors.
- **Micro Dashboard Server**: The chosen web UI (Yacd, Metacubexd, Zashboard) is served by an isolated `darkhttpd` systemd service. CORS headers are pre-configured for all three dashboard origins so the auth link flow works out of the box.
- **Secure TUN Mode** (NixOS): When `tun.enable = true`, the NixOS module automatically creates a dedicated `clashix` system user and grants it `CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE` as ambient capabilities. Mihomo never runs as root.
- **Configurable TUN Stack**: Choose between `system` (default), `gvisor`, or `mixed` stack via `tun.stack`.

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
  port      = 7890;
  socksPort = 7891;
  mixedPort = 7892;
  allowLan  = true;
  mode      = "Rule";

  # Dashboard (served by a dedicated darkhttpd process)
  dashboard = {
    enable      = true;
    type        = "yacd"; # "none" | "yacd" | "metacubexd" | "zashboard"
    port        = 8080;
    bindAddress = "0.0.0.0";
  };

  # Controller secret — use sops-nix or agenix for production deployments
  secret = "your-secret-here";

  # Subscriptions — first URL is the primary config, rest merge proxies only
  subscriptionUrls = [
    "https://your.sub.link/1"
    "https://your.sub.link/2"
  ];
  updateInterval = "daily";

  # TUN transparent proxy (NixOS: runs as dedicated 'clashix' user, no root)
  tun = {
    enable = true;
    stack  = "system"; # "system" | "gvisor" | "mixed"
  };

  # Arbitrary extra Mihomo YAML keys merged on top
  extraConfig = {
    ipv6 = false;
  };
};
```

### 2. Home Manager with Flakes

Import the module in your Home Manager configuration:

```nix
modules = [
  clashix.homeManagerModules.clashix
  ./home.nix
]
```

Configuration syntax inside `home.nix` is identical to NixOS. Services run as systemd *user* services.

> **Note on TUN Mode**: Under standalone Home Manager (non-NixOS), user services cannot hold `CAP_NET_ADMIN`. The NixOS module handles this automatically via a dedicated system user; under Home Manager you must grant capabilities manually:
>
> ```bash
> mkdir -p ~/.local/bin
> cp $(readlink -f $(which mihomo)) ~/.local/bin/mihomo-cap
> sudo setcap 'cap_net_admin,cap_net_bind_service=+ep' ~/.local/bin/mihomo-cap
> ```
>
> Then point Clashix at that binary:
>
> ```nix
> programs.clashix = {
>   enable     = true;
>   tun.enable = true;
>   package    = pkgs.writeShellScriptBin "mihomo" ''
>     exec ~/.local/bin/mihomo-cap "$@"
>   '';
> };
> ```

### 3. NixOS without Flakes (Legacy)

```nix
{ config, pkgs, ... }:
let
  clashix = fetchTarball "https://github.com/DawnMagnet/clashix/archive/main.tar.gz";
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
  clashix = fetchTarball "https://github.com/DawnMagnet/clashix/archive/main.tar.gz";
in
{
  imports = [ "${clashix}/modules/home-manager" ];
  programs.clashix.enable = true;
}
```

### 5. Nix Shell Support (Instant Environment)

Enter a fully working proxy + dashboard environment without installing anything permanently. Useful for quick tests or CI.

> [!NOTE]
> Proxy environment variables (`http_proxy`, `https_proxy`, `all_proxy`) are **only** exported automatically inside these shell environments, not by the NixOS/Home Manager modules during a normal system activation.

#### Using nix develop (Flakes)

```bash
nix develop github:DawnMagnet/clashix
```

#### Using nix-shell (classic)

```bash
nix-shell https://github.com/DawnMagnet/clashix/archive/main.tar.gz
```

Upon entering the shell:

- Mihomo and the dashboard (darkhttpd) start in the background with a random one-time secret.
- `http_proxy`, `https_proxy`, and `all_proxy` are automatically exported.
- The printed **Login URL** embeds the generated secret — paste it in your browser to connect immediately.
- Everything (processes, temp files) is cleaned up when you exit the shell.

## Dashboard Auth Link

When `secret` is set, the dashboard UI needs to connect to the controller using that secret. All three supported dashboard types (Yacd, Metacubexd, Zashboard) support a setup URL of the form:

```text
http://<dashboard-host>:<dashboard-port>/#/setup?hostname=<bind-addr>&port=<controller-port>&secret=<secret>
```

Clashix pre-configures `external-controller-cors` with the canonical allow-origins list for all three dashboard domains, so browser requests from the dashboard page to the controller are permitted without CORS errors.

## NixOS vs Home Manager

| Capability | NixOS module | Home Manager module |
| --- | --- | --- |
| Runs as dedicated system user | Yes (`clashix` user + group) | No (runs as your user) |
| TUN mode (CAP_NET_ADMIN) | Automatic via ambient capabilities | Manual `setcap` on binary |
| Config generation tracking | Yes (preStart) | Yes (activation script) |
| Subscription auto-update | systemd timer (system) | systemd timer (user) |

## Testing

The project ships a suite of 10 independent NixOS VM tests runnable with:

```bash
nix build .#checks.x86_64-linux.<test-name>
```

| Test | What it covers |
| --- | --- |
| `basicTest` | Default config, all 5 ports open, dashboard HTML, REST API JSON |
| `portsAndSecretTest` | Custom ports, HTTP 401/200 secret auth on controller |
| `dashboardTypesTest` | `type=none` disables service; `type=yacd` serves HTML |
| `subscriptionTest` | End-to-end: mock server → xh GET → proxy merged, Nix settings retained |
| `multiSubscriptionTest` | Two subscriptions: both proxies present, `proxy-groups` deduplicated |
| `tunTest` | `clashix` user/group created, `User=clashix` + `CAP_NET_ADMIN` in unit |
| `tunStackTest` | `tun.stack = "gvisor"` appears in `config.yaml` |
| `generationTest` | Corrupt `.nix-gen` → restart → preStart re-applies Nix overlay |
| `dashboardAuthTest` | Dashboard HTML (no auth); controller 401/200; `/proxies`, `/configs`, `/version` JSON; CORS allow/deny |
| `allowLanTest` | `allowLan=true` binds `*:7890`; `allowLan=false` binds `127.0.0.1:7890` |
