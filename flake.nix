{
  description = "A declarative Nix module for Mihomo (Clash Meta) with integrated web dashboards";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
      in
      {
        # 自定义包导出
        packages = {
          yacd = pkgs.callPackage ./pkgs/yacd { };
          metacubexd = pkgs.callPackage ./pkgs/metacubexd { };
          zashboard = pkgs.callPackage ./pkgs/zashboard { };
        };

        # 格式化器
        formatter = pkgs.nixpkgs-fmt;

        # 开发 Shell
        devShells.default =
          let
            clashixLib = import ./modules/clashix-lib.nix {
              inherit (pkgs) lib;
              inherit pkgs;
            };
          in
          clashixLib.mkShell { };

        # 测试用例 — 每个 check 独立运行，可通过以下命令单独执行：
        #   nix build .#checks.x86_64-linux.<test-name>
        checks = import ./checks { inherit self pkgs lib; };
      }
    )
    // {
      # 导出 NixOS 模块和 Home Manager 模块
      nixosModules.default = import ./modules/nixos;
      nixosModules.clashix = self.nixosModules.default;

      homeManagerModules.default = import ./modules/home-manager;
      homeManagerModules.clashix = self.homeManagerModules.default;

      # 导出库
      lib.mkShell =
        pkgs:
        let
          clashixLib = import ./modules/clashix-lib.nix {
            inherit (pkgs) lib;
            inherit pkgs;
          };
        in
        clashixLib.mkShell;
    };
}
