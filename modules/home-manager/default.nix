{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.clashix;

  # Import options, passing isHomeManager = true
  sharedOptions = import ../shared.nix {
    inherit lib pkgs config;
    isHomeManager = true;
  };

  # Select the correct dashboard package based on config
  dashboardPkg =
    if cfg.dashboard.type == "yacd" then
      pkgs.callPackage ../../pkgs/yacd { }
    else if cfg.dashboard.type == "metacubexd" then
      pkgs.callPackage ../../pkgs/metacubexd { }
    else if cfg.dashboard.type == "zashboard" then
      pkgs.callPackage ../../pkgs/zashboard { }
    else
      null;

  dashboardPath = if dashboardPkg != null then "${dashboardPkg}/share/${cfg.dashboard.type}" else "";

  # Base generated configuration
  baseConfig = {
    port = cfg.port;
    socks-port = cfg.socksPort;
    mixed-port = cfg.mixedPort;
    allow-lan = cfg.allowLan;
    mode = cfg.mode;
    log-level = cfg.logLevel;
    external-controller = "${cfg.dashboard.bindAddress}:${toString cfg.controllerPort}";
    secret = cfg.secret;
  }
  // (optionalAttrs cfg.tun.enable {
    tun = {
      enable = true;
      stack = "system"; # or gvisor/mixed
      auto-route = true;
      auto-detect-interface = true;
    };
  });

  # Merge the base config with the user's extraConfig
  finalConfig = recursiveUpdate baseConfig cfg.extraConfig;

  configFile = pkgs.writeText "clashix-config.yaml" (builtins.toJSON finalConfig);

  # stateDir for Home Manager (typically ~/.config/clashix or ~/.local/state/clashix)
  # We use the XDG state home
  stateDir = "${config.xdg.stateHome}/clashix";

in
{
  options.programs.clashix = sharedOptions.options.programs.clashix;

  config = mkIf cfg.enable {

    # Pre-create state directory and basic config for HM
    home.activation.setupClashixConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${stateDir}
      if [ ! -f ${stateDir}/config.yaml ]; then
        cp ${configFile} ${stateDir}/config.yaml
        chmod 600 ${stateDir}/config.yaml
      fi
    '';

    # 1. Provide the main Systemd User service for Mihomo
    systemd.user.services.clashix = {
      Unit = {
        Description = "Mihomo daemon (programs.clashix via Home Manager)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };

      Install = {
        WantedBy = [ "default.target" ];
      };

      Service = {
        ExecStart = "${cfg.package}/bin/mihomo -d ${stateDir} -f ${stateDir}/config.yaml";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        # Note: TUN mode under User Services is generally problematic without wrappers or CAP_NET_ADMIN on the binary
        # Which NixOS handles via wrappers, but under pure HM on non-NixOS it might fail.
        # We assume the user has set up sudo rules or capability wrappers if they enable tun in HM.
      };
    };

    systemd.user.services.clashix-dashboard =
      mkIf (cfg.dashboard.enable && cfg.dashboard.type != "none")
        {
          Unit = {
            Description = "Clashix Web Dashboard Service (darkhttpd, User)";
            After = [ "network-online.target" ];
            Wants = [ "network-online.target" ];
          };

          Install = {
            WantedBy = [ "default.target" ];
          };

          Service = {
            ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress}";
            Restart = "on-failure";
          };
        };

    # 2. Provide the Subscription Update Timer and Service for User
    systemd.user.services.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      Unit = {
        Description = "Update Clashix Subscriptions (User)";
        After = [ "network-online.target" ];
      };

      Service = {
        Type = "oneshot";
        Environment = "PATH=${
          lib.makeBinPath [
            pkgs.curl
            pkgs.yq
            pkgs.jq
            pkgs.coreutils
            targetPackages.systemd
          ]
        }";
        ExecStart = pkgs.writeShellScript "clashix-update-hm" ''
          echo "Updating subscriptions..."
          merged_file=$(mktemp)
          urls=(${concatStringsSep " " (map (u: "\"${u}\"") cfg.subscriptionUrls)})

          cp ${configFile} "$merged_file"
          ${pkgs.yq}/bin/yq -i '.proxies //= [] | .["proxy-groups"] //= []' "$merged_file"

          for url in "''${urls[@]}"; do
            echo "Fetching $url..."
            temp_sub=$(mktemp)
            if curl -sL --compressed -A "clash-verge/v2.4.3" --retry 3 "$url" -o "$temp_sub"; then

              # Check if valid YAML
              if ! ${pkgs.yq}/bin/yq e '.' "$temp_sub" >/dev/null 2>&1; then
                echo "Content is not valid YAML, attempting Base64 decode..."
                ${pkgs.coreutils}/bin/base64 -d "$temp_sub" > "$temp_sub.decoded" 2>/dev/null || true
                if ${pkgs.yq}/bin/yq e '.' "$temp_sub.decoded" >/dev/null 2>&1; then
                  mv "$temp_sub.decoded" "$temp_sub"
                  echo "Base64 decode successful."
                else
                  echo "Warning: Fetched content is not valid YAML even after Base64 decoding. Skipping."
                  rm -f "$temp_sub.decoded"
                  rm -f "$temp_sub"
                  continue
                fi
              fi

              ${pkgs.yq}/bin/yq eval-all '
                select(fileIndex == 0).proxies += (select(fileIndex == 1).proxies // []) |
                select(fileIndex == 0)["proxy-groups"] += (select(fileIndex == 1)["proxy-groups"] // []) |
                select(fileIndex == 0)
              ' "$merged_file" "$temp_sub" > "$merged_file.tmp"
              mv "$merged_file.tmp" "$merged_file"
            else
              echo "Failed to fetch $url, skipping..."
            fi
            rm -f "$temp_sub"
          done

          if [ -s "$merged_file" ]; then
            mv "$merged_file" ${stateDir}/config.yaml
            chmod 600 ${stateDir}/config.yaml
            echo "Reloading user clashix service..."
            systemctl --user reload clashix.service
          else
            echo "Merged configuration is empty. Keeping old configuration."
          fi
          rm -f "$merged_file"
        '';
      };
    };

    systemd.user.timers.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      Unit = {
        Description = "Timer to update Clashix subscriptions (User)";
      };

      Timer = {
        OnCalendar = cfg.updateInterval;
        Persistent = true;
      };

      Install = {
        WantedBy = [ "timers.target" ];
      };
    };

  };
}
