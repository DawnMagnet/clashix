{
  pkgs ? import <nixpkgs> { },
  subscriptionUrls ? [ ],
}:

let
  inherit (pkgs) lib;
  clashixLib = import ./modules/clashix-lib.nix { inherit lib pkgs; };

in
clashixLib.mkShell {
  clashixConfig = {
    inherit subscriptionUrls;
  };
}
