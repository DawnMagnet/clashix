# programs.clashix 🚀

[🌐 English README](README.md)

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

*关于 TUN 透明代理的提示*：在非 NixOS 的纯 Home Manager 环境中，普通用户的 Systemd 服务默认没有接管路由表的特权 (`CAP_NET_ADMIN`)，直接开启 TUN 会导致崩溃。为了在不使用全局 root 的前提下无缝开启 TUN 模式，您可以为一份本地拷贝赋予网络特权：

1. 拷贝二进制并赋予内核能力（仅需执行一次）：
   ```bash
   mkdir -p ~/.local/bin
   cp $(readlink -f $(which mihomo)) ~/.local/bin/mihomo-cap
   sudo setcap 'cap_net_admin,cap_net_bind_service=+ep' ~/.local/bin/mihomo-cap
   ```

2. 在您的 `home.nix` 中指定模块使用该授权文件：
   ```nix
   programs.clashix = {
     enable = true;
     tun.enable = true;
     package = pkgs.writeShellScriptBin "mihomo" ''
       exec ~/.local/bin/mihomo-cap "$@"
     '';
     # ... 其它配置
   };
   ```

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
