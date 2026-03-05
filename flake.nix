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

        # 测试用例
        checks = {
          vmTest = pkgs.testers.nixosTest {
            name = "clashix-test";
            nodes.machine =
              { ... }:
              {
                imports = [ self.nixosModules.default ];
                programs.clashix = {
                  enable = true;
                  dashboard.type = "yacd";
                };
              };
            testScript = ''
              machine.wait_for_unit("clashix.service")
              machine.wait_for_unit("clashix-dashboard.service")
              machine.wait_for_open_port(8080)
              machine.wait_for_open_port(9090)

              response = machine.succeed("curl -s http://127.0.0.1:8080")
              assert "html" in response.lower(), "Dashboard did not return HTML"
            '';
          };
        };
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
