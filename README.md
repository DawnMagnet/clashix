# programs.clashix 🚀  [中文说明](#中文说明)

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
    clashix.url = "github:yourname/clashix"; # Replace with actual path/repo
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
*Note: Using `tun.enable = true` under Home Manager might require manual sudo wrapper setups depending on your system.*

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
  # ... rest of config
}
```

---

<span id="中文说明"></span>

# programs.clashix 🚀

一个声明式的、无需 GUI 的基于 NixOS 与 Home Manager 的 Mihomo (Clash Meta) 客户端模块。内置独立的 Web 静态面板 (Yacd, Metacubexd, 或 Zashboard) 支持。

## 特性

- **完全声明式**: 通过原生的 Nix 模块选项直接管理代理端口、代理模式、局域网访问等核心配置。
- **多订阅聚合**: 支持配置列表形式的多个订阅链接，系统会自动设定 systemd 定时任务将它们抓取并使用 `yq` 合并入运行时配置。
- **独立的微型面板服务**: 面板资源将由专门的 `darkhttpd` (轻量级静态服务器) systemd 服务托管，与 Mihomo 进程边界隔离。
- **TUN 模式下沉**: 透明代理级别的一键部署。

## 用法说明

### 1. 基于 Flake 的 NixOS 配置（推荐）

首先你的 `flake.nix` 中引入模块：

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    clashix.url = "github:yourname/clashix"; # 这里替换为实际的仓库或本地目录
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

然后在 `configuration.nix` 中：

```nix
programs.clashix = {
  enable = true;

  # 核心代理配置
  port = 7890;
  socksPort = 7891;
  mixedPort = 7892;
  allowLan = true;
  mode = "Rule";

  # 面板配置 (由独立进程提供)
  dashboard = {
    enable = true;
    type = "yacd"; # 可选: "none" (关闭面板), "yacd", "metacubexd", "zashboard"
    port = 8080;
    bindAddress = "0.0.0.0";
  };

  # 多订阅处理
  subscriptionUrls = [
    "https://your.sub.link/1"
    "https://your.sub.link/2"
  ];
  updateInterval = "daily"; # 定时更新频率

  # 其他需要合并到底层配置文件的参数
  extraConfig = {
    ipv6 = false;
  };
};
```

### 2. 基于 Flake 的 Home Manager 配置

引用方式类似，在 `home.nix` 的 `modules` 中加入 `clashix.homeManagerModules.clashix` 即可。

其余配置与 NixOS 完全相同，服务将以 Systemd User Service 的身份挂在这个用户下。
*注意：在 Home Manager 中通过 `tun.enable = true` 开启透明代理可能需要您自己配置对应的提权策略（比如 Capabilities 或 sudo 包裹），因为普通用户权限通常无法直接接管路由。*

### 3. 非 Flake 环境下的 NixOS (使用 fetchTarball)

在你的配置文件中，直接通过外部源码引用：

```nix
{ config, pkgs, ... }:
let
  clashix = fetchTarball "https://github.com/yourname/clashix/archive/main.tar.gz";
in
{
  imports = [ "${clashix}/modules/nixos" ];

  programs.clashix = {
    enable = true;
    dashboard.type = "metacubexd";
    # ... 配置其它项
  };
}
```

### 4. 非 Flake 环境下的 Home Manager

相似的导入方式：

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
