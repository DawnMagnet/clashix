{ lib, pkgs }:

let
  inherit (lib)
    optionalAttrs
    recursiveUpdate
    optionalString
    ;

  # Pre-bundled geodata fetched via jsDelivr CDN.
  # Copied into STATE_DIR before mihomo starts so it never needs to download them.
  geodataFiles = {
    mmdb = pkgs.fetchurl {
      url = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb";
      sha256 = "0xnsgpxlpqzlf2mpg6gy2ha4cql4lcld2zhjbl4ilrrl9mbcqcvr";
    };
    geoip = pkgs.fetchurl {
      url = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat";
      sha256 = "0jxhaihblyh07jwhv5sb3pv5k0jg4516ssdkq9r24mldp65chzaz";
    };
    geosite = pkgs.fetchurl {
      url = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat";
      sha256 = "18jnzaplid44pf6dpy8mhkjl5psy0v9aqcq9fc0vy3cdv1n7js3p";
    };
  };

  # jsDelivr CDN URLs for geodata updates (used by mihomo when updating geodata at runtime)
  geoxUrls = {
    mmdb = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb";
    geoip = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat";
    geosite = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat";
    asn = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb";
  };

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
        # Override geodata update URLs to use CDN instead of GitHub
        geox-url = geoxUrls;
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

  # A script to apply subscriptions onto the config.
  #
  # Strategy: treat the subscription as the PRIMARY config, then overlay our
  # essential Nix-controlled settings (ports, controller, secret) on top.
  # This correctly handles complete subscription configs (which already contain
  # their own proxy-groups, rules, rule-providers, etc.) without causing
  # duplicate group name errors.
  mkUpdateScript =
    cfg:
    let
      urls = lib.concatStringsSep " " (lib.map (u: "\"${u}\"") cfg.subscriptionUrls);
      # Our essential settings that must always win, as a yq expression
      overlayExpr = lib.concatStringsSep " | " [
        ".port = ${toString cfg.port}"
        ''.["socks-port"] = ${toString cfg.socksPort}''
        ''.["mixed-port"] = ${toString cfg.mixedPort}''
        ''.["allow-lan"] = ${if cfg.allowLan then "true" else "false"}''
        ".mode = \"${cfg.mode}\""
        ''.["log-level"] = "${cfg.logLevel}"''
        ''.["external-controller"] = "${cfg.dashboard.bindAddress}:${toString cfg.controllerPort}"''
        ''.["external-controller-cors"].["allow-origins"] = ["https://yacd.metacubex.one","https://metacubex.github.io","https://board.zash.run.place"]''
        ''.["external-controller-cors"].["allow-private-network"] = true''
      ];
    in
    pkgs.writeShellScriptBin "clashix-update" ''
      set -e
      CONFIG_FILE="''${1:-config.yaml}"
      SECRET="''${2:-}"
      echo "--- Updating subscriptions ---"

      FIRST_URL=true
      URLS=(${urls})
      for url in "''${URLS[@]}"; do
        echo "Fetching $url..."
        temp_sub=$(mktemp)
        if env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
          ${pkgs.xh}/bin/xh "$url" User-Agent:"clash-verge/v2.4.3" -o "$temp_sub"; then

          # Base64 decode if not valid YAML
          if ! ${pkgs.yq-go}/bin/yq e '.' "$temp_sub" >/dev/null 2>&1; then
            ${pkgs.toybox}/bin/base64 -d "$temp_sub" > "$temp_sub.decoded" 2>/dev/null || true
            if ${pkgs.yq-go}/bin/yq e '.' "$temp_sub.decoded" >/dev/null 2>&1; then
              mv "$temp_sub.decoded" "$temp_sub"
            fi
          fi

          if ${pkgs.yq-go}/bin/yq e '.' "$temp_sub" >/dev/null 2>&1; then
            if [ "$FIRST_URL" = "true" ]; then
              # First subscription: use it as the base, overlay our settings on top
              ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' "$temp_sub"
              # Apply secret if provided
              if [ -n "$SECRET" ]; then
                ${pkgs.yq-go}/bin/yq -i ".secret = \"$SECRET\"" "$temp_sub"
              fi
              cp "$temp_sub" "$CONFIG_FILE"
              FIRST_URL=false
            else
              # Additional subscriptions: only merge proxies (not proxy-groups, to avoid naming conflicts)
              ${pkgs.yq-go}/bin/yq eval-all -i '
                select(fileIndex == 0).proxies += (select(fileIndex == 1).proxies // []) |
                select(fileIndex == 0)
              ' "$CONFIG_FILE" "$temp_sub"
            fi
          fi
        fi
        rm -f "$temp_sub"
      done
    '';

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
      updateScript = mkUpdateScript cfg;

      # The main entrypoint for the shell.
      # It runs synchronously in shellHook: starts services in background,
      # saves PIDs to a state file, prints info, then exits.
      # This ensures all output appears before the interactive shell prompt.
      runClashix = pkgs.writeShellScriptBin "clashix-run" ''
        STATE_DIR=$(mktemp -d /tmp/clashix-shell.XXXXXX)
        CONFIG_FILE="$STATE_DIR/config.yaml"
        cp ${clashConfigFile} "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"

        # Secret generation
        SECRET="${cfg.secret}"
        if [ -z "$SECRET" ]; then
          SECRET=$(printf "%06d" $((RANDOM % 1000000)))
          ${pkgs.yq-go}/bin/yq -i ".secret = \"$SECRET\"" "$CONFIG_FILE"
        fi

        # Fetch subscriptions before starting mihomo.
        # clashix-update will use the subscription as the primary config and
        # overlay our essential settings (including the secret) on top.
        # If no subscriptions are provided, we fall back to the base config.
        ${optionalString (cfg.subscriptionUrls != [ ]) ''
          ${updateScript}/bin/clashix-update "$CONFIG_FILE" "$SECRET"
        ''}
        ${optionalString (cfg.subscriptionUrls == [ ]) ''
          ${pkgs.yq-go}/bin/yq -i ".secret = \"$SECRET\"" "$CONFIG_FILE"
        ''}

        # --- Cleanup any stale previous session ---
        # If a previous clashix-run left a state dir (e.g. shell was killed),
        # terminate those processes now before we try to bind the same ports.
        _PREV_STATE=$(cat /tmp/.clashix-active-state-dir 2>/dev/null || true)
        if [ -n "$_PREV_STATE" ] && [ -d "$_PREV_STATE" ]; then
          echo "Cleaning up previous session in $_PREV_STATE..."
          if [ -f "$_PREV_STATE/mihomo.pid" ]; then
            kill "$(cat "$_PREV_STATE/mihomo.pid")" 2>/dev/null || true
          fi
          if [ -f "$_PREV_STATE/dashboard.pid" ]; then
            kill "$(cat "$_PREV_STATE/dashboard.pid")" 2>/dev/null || true
          fi
          rm -rf "$_PREV_STATE"
        fi
        rm -f /tmp/.clashix-active-state-dir
        # Give processes a moment to release their ports
        sleep 0.5

        # Pre-populate geodata from Nix store so mihomo never needs to download them
        cp ${geodataFiles.mmdb}    "$STATE_DIR/geoip.metadb"
        cp ${geodataFiles.geoip}   "$STATE_DIR/geoip.dat"
        cp ${geodataFiles.geosite} "$STATE_DIR/geosite.dat"
        chmod 644 "$STATE_DIR/geoip.metadb" "$STATE_DIR/geoip.dat" "$STATE_DIR/geosite.dat"

        # Start services in background
        ${cfg.package}/bin/mihomo -d "$STATE_DIR" -f "$CONFIG_FILE" > "$STATE_DIR/mihomo.log" 2>&1 &
        echo $! > "$STATE_DIR/mihomo.pid"

        ${optionalString (cfg.dashboard.enable && cfg.dashboard.type != "none") ''
          ${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress} > /dev/null 2>&1 &
          echo $! > "$STATE_DIR/dashboard.pid"
          DASHBOARD_URL="http://${cfg.dashboard.bindAddress}:${toString cfg.dashboard.port}"
          SETUP_URL="$DASHBOARD_URL/#/setup?hostname=${cfg.dashboard.bindAddress}&port=${toString cfg.controllerPort}&secret=$SECRET"
        ''}

        # Let the shellHook know where we stored state
        echo "$STATE_DIR" > /tmp/.clashix-active-state-dir

        # Print info now — this is synchronous, so it appears before the prompt
        echo ""
        echo "--- Clashix Active ---"
        echo "Proxy:      socks5://${cfg.dashboard.bindAddress}:${toString cfg.socksPort}"
        ${optionalString (cfg.dashboard.enable && cfg.dashboard.type != "none") ''
          echo "Dashboard:  $DASHBOARD_URL"
          echo "Login URL:  $SETUP_URL"
        ''}
        echo "Logs:       $STATE_DIR/mihomo.log"
        echo "Tip:        Type 'exit' or Ctrl+D to stop all services."
        echo ""
      '';

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
          updateScript
          runClashix
        ];

        shellHook = ''
          export http_proxy="http://127.0.0.1:${toString cfg.port}"
          export https_proxy="http://127.0.0.1:${toString cfg.port}"
          export all_proxy="socks5://127.0.0.1:${toString cfg.socksPort}"
          export HTTP_PROXY="$http_proxy"
          export HTTPS_PROXY="$https_proxy"
          export ALL_PROXY="$all_proxy"

          # Run synchronously: starts services, prints info, then returns control to the shell
          clashix-run

          # Export state dir so the trap function can reliably access it
          export CLASHIX_STATE_DIR
          CLASHIX_STATE_DIR=$(cat /tmp/.clashix-active-state-dir 2>/dev/null || echo "")

          _clashix_cleanup() {
            echo ""
            echo "Stopping Clashix..."

            _kill_pid_file() {
              local pid_file="$1"
              if [ -f "$pid_file" ]; then
                local pid
                pid=$(cat "$pid_file")
                kill -TERM "$pid" 2>/dev/null || true
                # Wait up to 3s then SIGKILL
                local i=0
                while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 6 ]; do
                  sleep 0.5; i=$((i + 1))
                done
                kill -KILL "$pid" 2>/dev/null || true
              fi
            }

            _kill_pid_file "$CLASHIX_STATE_DIR/mihomo.pid"
            _kill_pid_file "$CLASHIX_STATE_DIR/dashboard.pid"
            rm -rf "$CLASHIX_STATE_DIR" 2>/dev/null || true
            rm -f /tmp/.clashix-active-state-dir
            echo "Clashix stopped."
          }

          trap _clashix_cleanup EXIT INT TERM
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
    mkUpdateScript
    ;
}
