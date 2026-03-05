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
    pkgs.mkShellNoCC (
      (removeAttrs args [ "clashixConfig" ])
      // {
        buildInputs = (args.buildInputs or [ ]) ++ [
          cfg.package
          pkgs.darkhttpd
          pkgs.xh # Added for subscriptionUrls
          pkgs.yq-go # Added for subscriptionUrls
          pkgs.toybox # Added for base64 in subscriptionUrls
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
          CONFIG_FILE="$STATE_DIR/config.yaml"
          cp ${clashConfigFile} "$CONFIG_FILE"

          # Handle secret generation if empty
          SECRET="${cfg.secret}"
          if [ -z "$SECRET" ]; then
            SECRET=$(printf "%06d" $((RANDOM % 1000000)))
            ${pkgs.yq-go}/bin/yq -i ".secret = \"$SECRET\"" "$CONFIG_FILE"
          fi

          ${optionalString (cfg.subscriptionUrls != [ ]) ''
            echo "Fetching subscriptions..."
            urls=(${lib.concatStringsSep " " (lib.map (u: "\"${u}\"") cfg.subscriptionUrls)})
            ${pkgs.yq-go}/bin/yq -i '.proxies //= [] | .["proxy-groups"] //= []' "$CONFIG_FILE"

            for url in "''${urls[@]}"; do
              echo "Fetching $url..."
              temp_sub=$(mktemp)
              if ${pkgs.xh}/bin/xh -F -q "$url" User-Agent:"clash-verge/v2.4.3" -o "$temp_sub"; then
                if ! ${pkgs.yq-go}/bin/yq e '.' "$temp_sub" >/dev/null 2>&1; then
                  ${pkgs.toybox}/bin/base64 -d "$temp_sub" > "$temp_sub.decoded" 2>/dev/null || true
                  if ${pkgs.yq-go}/bin/yq e '.' "$temp_sub.decoded" >/dev/null 2>&1; then
                    mv "$temp_sub.decoded" "$temp_sub"
                  else
                    rm -f "$temp_sub.decoded" "$temp_sub"
                    continue
                  fi
                fi
                ${pkgs.yq-go}/bin/yq eval-all '
                  select(fileIndex == 0).proxies += (select(fileIndex == 1).proxies // []) |
                  select(fileIndex == 0)["proxy-groups"] += (select(fileIndex == 1)["proxy-groups"] // []) |
                  select(fileIndex == 0)
                ' "$CONFIG_FILE" "$temp_sub" > "$CONFIG_FILE.tmp"
                mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
              fi
              rm -f "$temp_sub"
            done
          ''}

          ${cfg.package}/bin/mihomo -d "$STATE_DIR" -f "$CONFIG_FILE" > "$STATE_DIR/mihomo.log" 2>&1 &
          MIHOMO_PID=$!

          ${optionalString (cfg.dashboard.enable && cfg.dashboard.type != "none") ''
            ${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress} > /dev/null 2>&1 &
            DASHBOARD_PID=$!
            echo "Dashboard (${cfg.dashboard.type}): http://${cfg.dashboard.bindAddress}:${toString cfg.dashboard.port}"
          ''}

          echo "Control Port: ${toString cfg.controllerPort}"
          echo "Control Secret: $SECRET"
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
