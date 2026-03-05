{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.clashix;

  # Import options, passing isHomeManager = false
  sharedOptions = import ../shared.nix {
    inherit lib pkgs config;
    isHomeManager = false;
  };

  clashixLib = import ../clashix-lib.nix { inherit lib pkgs; };

  dashboardPath = clashixLib.getDashboardPath cfg;

  # Base generated configuration
  finalConfig = clashixLib.mkClashConfig cfg;

  configFile = pkgs.writeText "clashix-config.yaml" (builtins.toJSON finalConfig);

  # The directory where Mihomo stores run-time data and downloaded providers
  stateDir = "/var/lib/clashix";

in
{
  options.programs.clashix = sharedOptions.options.programs.clashix;

  config = mkIf cfg.enable {

    # 1. Provide the main Systemd service for Mihomo
    systemd.services.clashix = {
      description = "Mihomo daemon (programs.clashix)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/mihomo -d ${stateDir} -f ${stateDir}/config.yaml";
        ExecReload = "${pkgs.toybox}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        StateDirectory = "clashix";

        # Hardening / Capabilities
        AmbientCapabilities = lib.mkIf cfg.tun.enable [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        CapabilityBoundingSet = lib.mkIf cfg.tun.enable [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];

        # Using root if tun is enabled just to be safe, otherwise we could use DynamicUser but need care for statedir permissions.
        # Mihomo needs root/CAP_NET_ADMIN for tun.
        DynamicUser = !cfg.tun.enable;
      };

      # Initial setup of config.yaml
      preStart = ''
        if [ ! -f ${stateDir}/config.yaml ]; then
          cp ${configFile} ${stateDir}/config.yaml
          chmod 600 ${stateDir}/config.yaml
        fi
      '';
    };

    systemd.services.clashix-dashboard = mkIf (cfg.dashboard.enable && cfg.dashboard.type != "none") {
      description = "Clashix Web Dashboard Service (darkhttpd)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress}";
        Restart = "on-failure";
        DynamicUser = true;
      };
    };

    # 2. Provide the Subscription Update Timer and Service
    systemd.services.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      description = "Update Clashix Subscriptions";
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];

      path = [
        pkgs.xh
        pkgs.yq-go
        pkgs.toybox
      ];

      script = ''
        echo "Updating subscriptions..."
        merged_file=$(mktemp)
        urls=(${concatStringsSep " " (map (u: "\"${u}\"") cfg.subscriptionUrls)})

        # We start with the base declarative config
        cp ${configFile} "$merged_file"

        # Initialize proxy array if it doesn't exist
        yq -i '.proxies //= [] | .["proxy-groups"] //= []' "$merged_file"

        for url in "''${urls[@]}"; do
          echo "Fetching $url..."
          temp_sub=$(mktemp)
          if xh -F -q "$url" User-Agent:"clash-verge/v2.4.3" -o "$temp_sub"; then

            # Check if it's valid yaml. If not, try base64 decode
            if ! yq e '.' "$temp_sub" >/dev/null 2>&1; then
              echo "Content is not valid YAML, attempting Base64 decode..."
              # Base64 decode might contain padding, ignore failures and check yaml validity again
              base64 -d "$temp_sub" > "$temp_sub.decoded" 2>/dev/null || true
              if yq e '.' "$temp_sub.decoded" >/dev/null 2>&1; then
                mv "$temp_sub.decoded" "$temp_sub"
                echo "Base64 decode successful."
              else
                echo "Warning: Fetched content is not valid YAML even after Base64 decoding. Skipping."
                rm -f "$temp_sub.decoded"
                rm -f "$temp_sub"
                continue
              fi
            fi

            # Extract proxies and proxy-groups from the subscription and append them to our merged config
            # (In a real advanced setup, you'd configure proxy-providers instead, but merging proxies works for simple cases)
            yq eval-all '
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
          echo "Reloading clashix service..."
          systemctl reload clashix.service
        else
          echo "Merged configuration is empty. Keeping old configuration."
        fi
        rm -f "$merged_file"
      '';

      serviceConfig = {
        Type = "oneshot";
        # We need root or the same permissions as the state directory
      };
    };

    systemd.timers.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      description = "Timer to update Clashix subscriptions";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.updateInterval;
        Persistent = true;
      };
    };

  };
}
