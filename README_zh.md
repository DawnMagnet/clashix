# programs.clashix 🚀

[🌐 English README](README.md)

一个声明式的、无需 GUI 的基于 NixOS 与 Home Manager 的 Mihomo (Clash Meta) 客户端模块。内置独立的 Web 静态面板 (Yacd, Metacubexd, 或 Zashboard) 支持。

## 特性

- **完全声明式**：通过原生 Nix 选项管理代理端口、模式、局域网访问等核心配置。每次服务重启时，模块都会通过「Generation 追踪」机制自动重新应用 Nix 声明的配置，`nixos-rebuild` 后无需手动修改任何文件。
- **多订阅智能合并**：支持配置多个订阅 URL。第一个 URL 的配置作为主配置（包含 proxy-groups、rules 等完整结构）；后续 URL 仅合并其 `proxies` 列表，彻底避免 proxy-group 重名冲突。
- **独立面板微服务**：面板资源（Yacd / Metacubexd / Zashboard）由专用的 `darkhttpd` systemd 服务托管，与 Mihomo 进程边界隔离。三种面板的域名均已预置于 `external-controller-cors` 白名单，鉴权链接开箱即用，无 CORS 报错。
- **安全的 TUN 透明代理**（NixOS）：开启 `tun.enable = true` 时，NixOS 模块会自动创建专用系统用户 `clashix`，并通过 Ambient Capabilities 授予 `CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE`。Mihomo 永不以 root 身份运行。
- **可配置 TUN 协议栈**：通过 `tun.stack` 选项在 `system`（默认）、`gvisor`、`mixed` 之间切换。

## 用法说明

### 1. 基于 Flake 的 NixOS 配置（推荐）

在 `flake.nix` 中引入模块：

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

  # 核心代理端口
  port      = 7890;
  socksPort = 7891;
  mixedPort = 7892;
  allowLan  = true;
  mode      = "Rule";

  # 面板配置（由独立的 darkhttpd 进程提供）
  dashboard = {
    enable      = true;
    type        = "yacd"; # "none" | "yacd" | "metacubexd" | "zashboard"
    port        = 8080;
    bindAddress = "0.0.0.0";
  };

  # 控制器鉴权密钥 — 生产环境建议配合 sops-nix 或 agenix 管理
  secret = "your-secret-here";

  # 多订阅 — 第一个为主配置，其余仅合并 proxies
  subscriptionUrls = [
    "https://your.sub.link/1"
    "https://your.sub.link/2"
  ];
  updateInterval = "daily";

  # TUN 透明代理（NixOS 下自动以专用用户 + Capabilities 运行，无需 root）
  tun = {
    enable = true;
    stack  = "system"; # "system" | "gvisor" | "mixed"
  };

  # 额外合并到底层 YAML 配置的任意字段
  extraConfig = {
    ipv6 = false;
  };
};
```

### 2. 基于 Flake 的 Home Manager 配置

在 Home Manager 的 `modules` 列表中加入 `clashix.homeManagerModules.clashix`，其余配置与 NixOS 完全相同，服务以 Systemd User Service 的身份运行。

> **关于 TUN 透明代理的提示**：NixOS 模块会自动创建系统用户并授予网络特权；而在纯 Home Manager 环境中，用户服务默认不具备 `CAP_NET_ADMIN`，需手动处理：
>
> ```bash
> mkdir -p ~/.local/bin
> cp $(readlink -f $(which mihomo)) ~/.local/bin/mihomo-cap
> sudo setcap 'cap_net_admin,cap_net_bind_service=+ep' ~/.local/bin/mihomo-cap
> ```
>
> 然后在 `home.nix` 中指定该授权二进制：
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

### 3. 非 Flake 环境下的 NixOS（使用 fetchTarball）

```nix
{ config, pkgs, ... }:
let
  clashix = fetchTarball "https://github.com/DawnMagnet/clashix/archive/main.tar.gz";
in
{
  imports = [ "${clashix}/modules/nixos" ];
  programs.clashix.enable = true;
  # ... 配置其它项
}
```

### 4. 非 Flake 环境下的 Home Manager

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

### 5. Nix Shell 支持（即插即用环境）

无需安装模块，直接通过 Nix Shell 进入一个预配置好代理和面板的临时环境，适合快速测试或 CI/CD。

> [!NOTE]
> **注意**：代理环境变量（`http_proxy` 等）**仅**在 `nix-shell` / `nix develop` 交互式环境中自动导出，NixOS / Home Manager 正常安装时不会注入全局环境变量。

#### 使用 nix-shell（经典）

**不使用订阅，仅使用内置默认配置：**

```bash
nix-shell https://github.com/DawnMagnet/clashix/archive/main.tar.gz
```

**传入单个订阅链接：**

```bash
nix-shell https://github.com/DawnMagnet/clashix/archive/main.tar.gz \
  --arg subscriptionUrls '["https://your.provider.com/sub?token=xxx"]'
```

**传入多个订阅链接：**

```bash
nix-shell https://github.com/DawnMagnet/clashix/archive/main.tar.gz \
  --arg subscriptionUrls '["https://provider1.com/sub", "https://provider2.com/sub"]'
```

#### 使用 nix develop（Flakes）

Flake 的 devShell 使用内置默认配置（无订阅，Zashboard 面板）。`nix develop` 不支持传递参数；如需传入订阅链接，请使用上方的 `nix-shell` 方式。

```bash
nix develop github:DawnMagnet/clashix
```

#### 进入环境后

Shell 就绪后，终端会输出类似以下内容：

```text
--- Updating subscriptions ---
Fetching https://your.provider.com/sub?token=xxx...

--- Clashix Active ---
Proxy:      socks5://127.0.0.1:7891
Dashboard:  http://127.0.0.1:8080
Login URL:  http://127.0.0.1:8080/#/setup?hostname=127.0.0.1&port=9090&secret=<自动生成>
Logs:       /tmp/clashix-shell.XXXXXX/mihomo.log
Tip:        Type 'exit' or Ctrl+D to stop all services.
```

- 直接在浏览器中打开 **Login URL**，控制器地址和密钥已预填，点击即可进入面板。
- 当前终端已自动设置 `http_proxy`、`https_proxy`、`all_proxy`，`curl`、`git`、`wget` 等工具直接走代理。
- 输入 `exit` 或按 `Ctrl+D` 退出，所有后台进程和临时目录自动清理。

## 面板鉴权链接

设置 `secret` 后，面板 UI 通过以下格式的 URL 连接至控制器：

```text
http://<面板地址>:<面板端口>/#/setup?hostname=<绑定地址>&port=<控制器端口>&secret=<密钥>
```

Clashix 已将 Yacd、Metacubexd、Zashboard 三个面板域名统一预置到 `external-controller-cors` 白名单，浏览器从面板页面向控制器发起的跨域请求可以正常通过，无需任何额外配置。

## NixOS vs Home Manager 对比

| 能力 | NixOS 模块 | Home Manager 模块 |
| --- | --- | --- |
| 专用系统用户运行 | 是（自动创建 `clashix` 用户和组） | 否（以当前用户身份运行） |
| TUN 模式（CAP_NET_ADMIN） | 自动通过 Ambient Capabilities 授予 | 需手动 `setcap` |
| 配置 Generation 追踪 | 是（preStart 钩子） | 是（activation 脚本） |
| 订阅定时自动更新 | systemd 系统级 timer | systemd 用户级 timer |

## 测试

项目附带 10 个相互独立的 NixOS VM 测试，可单独运行：

```bash
nix build .#checks.x86_64-linux.<test-name>
```

| 测试名 | 验证内容 |
| --- | --- |
| `basicTest` | 默认配置、5 个端口全部开放、面板 HTML、REST API JSON |
| `portsAndSecretTest` | 自定义端口、控制器 HTTP 401/200 鉴权 |
| `dashboardTypesTest` | `type=none` 不启动服务；`type=yacd` 正常返回 HTML |
| `subscriptionTest` | 端到端：mock 服务器 → xh GET → 代理合并入配置，Nix 设置保留 |
| `multiSubscriptionTest` | 两个订阅：两个代理均出现，`proxy-groups` 不重复 |
| `tunTest` | `clashix` 用户/组存在，unit 文件含 `User=clashix` + `CAP_NET_ADMIN` |
| `tunStackTest` | `tun.stack = "gvisor"` 出现在 `config.yaml` 中 |
| `generationTest` | 损坏 `.nix-gen` → 重启 → preStart 重新应用 Nix overlay |
| `dashboardAuthTest` | 面板 HTML 无需鉴权；控制器 401/200；`/proxies`、`/configs`、`/version` 返回 JSON；CORS 白名单允许/拒绝 |
| `allowLanTest` | `allowLan=true` 绑定 `*:7890`；`allowLan=false` 绑定 `127.0.0.1:7890` |
