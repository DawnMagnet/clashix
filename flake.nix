{
  description = "A declarative Nix module for Mihomo (Clash Meta) with integrated web dashboards";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
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
      }
    ) // {
      # 导出 NixOS 模块和 Home Manager 模块
      nixosModules.default = import ./modules/nixos;
      nixosModules.clashix = self.nixosModules.default;

      homeManagerModules.default = import ./modules/home-manager;
      homeManagerModules.clashix = self.homeManagerModules.default;
    };
}
