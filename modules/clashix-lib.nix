{ lib, pkgs }:

let
  inherit (lib)
    optionalAttrs
    recursiveUpdate
    optionalString
    ;

  # Select the correct dashboard package based on config
  getDashboardPkg =
    cfg:
    if cfg.dashboard.type == "yacd" then
      pkgs.callPackage ../pkgs/yacd { }
    else if cfg.dashboard.type == "metacubexd" then
      pkgs.callPackage ../pkgs/metacubexd { }
    else if cfg.dashboard.type == "zashboard" then
      pkgs.callPackage ../pkgs/zashboard { }
    else
      null;

  getDashboardPath =
    cfg:
    let
      pkg = getDashboardPkg cfg;
    in
    if pkg != null then "${pkg}/share/${cfg.dashboard.type}" else "";

  # Generate the clash config object
  mkClashConfig =
    cfg:
    let
      baseConfig = {
        port = cfg.port;
        socks-port = cfg.socksPort;
        mixed-port = cfg.mixedPort;
        allow-lan = cfg.allowLan;
        mode = cfg.mode;
        log-level = cfg.logLevel;
        external-controller = "${cfg.dashboard.bindAddress}:${toString cfg.controllerPort}";
        external-controller-cors = {
          allow-origins = [
            "https://yacd.metacubex.one"
            "https://metacubex.github.io"
            "https://board.zash.run.place"
          ];
          allow-private-network = true;
        };
        secret = cfg.secret;
      }
      // (optionalAttrs cfg.tun.enable {
        tun = {
          enable = true;
          stack = "system";
          auto-route = true;
          auto-detect-interface = true;
        };
      });
    in
    recursiveUpdate baseConfig cfg.extraConfig;

  # Create a shell environment
  mkShell =
    {
      clashixConfig ? { },
      ...
    }@args:
    let
      # Use default options from shared.nix if not provided
      # We need to evaluate the options to get defaults
      shared = import ./shared.nix {
        inherit lib pkgs;
        config = { };
        isHomeManager = false;
      };

      # Simple way to get defaults for options
      getDefaults =
        options:
        lib.mapAttrs (
          name: value:
          if value ? default then
            value.default
          else if builtins.isAttrs value then
            getDefaults value
          else
            null
        ) options;

      # Merge provided config with defaults
      cfg = recursiveUpdate (getDefaults shared.options.programs.clashix) clashixConfig;

      finalClashConfig = mkClashConfig cfg;
      clashConfigFile = pkgs.writeText "clashix-shell-config.yaml" (builtins.toJSON finalClashConfig);
      dashboardPath = getDashboardPath cfg;

    in
    pkgs.mkShell (
      args
      // {
        buildInputs = (args.buildInputs or [ ]) ++ [
          cfg.package
          pkgs.darkhttpd
        ];

        shellHook = ''
          echo "--- Clashix Shell ---"
          export http_proxy="http://127.0.0.1:${toString cfg.port}"
          export https_proxy="http://127.0.0.1:${toString cfg.port}"
          export ftp_proxy="http://127.0.0.1:${toString cfg.port}"
          export all_proxy="socks5://127.0.0.1:${toString cfg.socksPort}"
          export HTTP_PROXY="$http_proxy"
          export HTTPS_PROXY="$https_proxy"
          export FTP_PROXY="$ftp_proxy"
          export ALL_PROXY="$all_proxy"

          STATE_DIR=$(mktemp -d /tmp/clashix-shell.XXXXXX)

          ${cfg.package}/bin/mihomo -d "$STATE_DIR" -f ${clashConfigFile} > "$STATE_DIR/mihomo.log" 2>&1 &
          MIHOMO_PID=$!

          ${optionalString (cfg.dashboard.enable && cfg.dashboard.type != "none") ''
            ${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress} > /dev/null 2>&1 &
            DASHBOARD_PID=$!
            echo "Dashboard (${cfg.dashboard.type}): http://${cfg.dashboard.bindAddress}:${toString cfg.dashboard.port}"
          ''}

          echo "Proxy: $all_proxy"
          echo "Logs are in $STATE_DIR/mihomo.log"

          cleanup() {
            echo "Stopping Clashix services..."
            kill $MIHOMO_PID ''${DASHBOARD_PID:+ $DASHBOARD_PID} 2>/dev/null
            rm -rf "$STATE_DIR"
          }
          trap cleanup EXIT
        ''
        + (args.shellHook or "");
      }
    );

in
{
  inherit
    getDashboardPkg
    getDashboardPath
    mkClashConfig
    mkShell
    ;
}
