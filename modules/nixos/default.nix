{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.clashix;

  sharedOptions = import ../shared.nix { inherit lib pkgs; };

  clashixLib = import ../clashix-lib.nix { inherit lib pkgs; };

  dashboardPath = clashixLib.getDashboardPath cfg;

  # Base generated configuration — serialised as proper YAML (not JSON)
  finalConfig = clashixLib.mkClashConfig cfg;
  configFile = (pkgs.formats.yaml { }).generate "clashix-config.yaml" finalConfig;

  # yq overlay expression that re-applies all Nix-controlled settings.
  # Stored in a Nix string so it can be embedded in both preStart and the
  # update service without duplication.
  overlayExpr = clashixLib.mkOverlayExpr cfg;

  # The directory where Mihomo stores run-time data and downloaded providers
  stateDir = "/var/lib/clashix";

in
{
  options.programs.clashix = sharedOptions.options.programs.clashix;

  config = mkIf cfg.enable {

    # Dedicated system user for TUN mode — avoids running the process as root
    # while still granting the required network capabilities.
    users.users.clashix = mkIf cfg.tun.enable {
      isSystemUser = true;
      group = "clashix";
      description = "Clashix/Mihomo proxy daemon";
    };
    users.groups.clashix = mkIf cfg.tun.enable { };

    # 1. Main Mihomo daemon
    systemd.services.clashix = {
      description = "Mihomo daemon (programs.clashix)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig =
        {
          ExecStart = "${cfg.package}/bin/mihomo -d ${stateDir} -f ${stateDir}/config.yaml";
          ExecReload = "${pkgs.toybox}/bin/kill -HUP $MAINPID";
          Restart = "on-failure";
          StateDirectory = "clashix";
        }
        // (
          if cfg.tun.enable then
            {
              # Dedicated user with only the required capabilities — not root
              DynamicUser = false;
              User = "clashix";
              Group = "clashix";
              AmbientCapabilities = [
                "CAP_NET_ADMIN"
                "CAP_NET_BIND_SERVICE"
              ];
              CapabilityBoundingSet = [
                "CAP_NET_ADMIN"
                "CAP_NET_BIND_SERVICE"
              ];
            }
          else
            {
              # Ephemeral dynamic user for maximum isolation when TUN is off
              DynamicUser = true;
            }
        );

      # Generation-aware initialisation:
      #  1. On first boot: seed config.yaml from bootstrapConfig (if provided)
      #     or the Nix-generated skeleton, then immediately overlay Nix settings.
      #  2. On every subsequent nixos-rebuild: re-apply the overlay whenever the
      #     evaluated config changes (configFile store-path acts as a generation
      #     marker). Port/mode/controller changes take effect without waiting for
      #     the subscription timer.
      #  3. Pre-populate geodata from the Nix store so mihomo never needs to
      #     download country.mmdb / geoip.dat / geosite.dat on first boot.
      preStart = ''
        # --- 1. Bootstrap config.yaml on first boot --------------------------------
        if [ ! -f ${stateDir}/config.yaml ]; then
          ${if cfg.bootstrapConfig != null then ''
            cp ${cfg.bootstrapConfig} ${stateDir}/config.yaml
          '' else ''
            cp ${configFile} ${stateDir}/config.yaml
          ''}
          chmod 600 ${stateDir}/config.yaml
          # Overlay Nix-controlled settings immediately so ports/controller are
          # correct from the very first start, regardless of what the seeded file
          # contained.
          ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
          # Record the generation marker so step 2 below is a no-op this boot.
          printf '%s' '${configFile}' > ${stateDir}/.nix-gen
        fi

        # --- 2. Re-apply overlay on generation change --------------------------------
        NIX_GEN_MARKER='${configFile}'
        if [ "$(cat ${stateDir}/.nix-gen 2>/dev/null)" != "$NIX_GEN_MARKER" ]; then
          ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
          printf '%s' "$NIX_GEN_MARKER" > ${stateDir}/.nix-gen
        fi

        # --- 3. Seed geodata from the Nix store (no network needed on first boot) ---
        if [ ! -f ${stateDir}/country.mmdb ]; then
          cp ${clashixLib.geodataFiles.mmdb} ${stateDir}/country.mmdb
          chmod 644 ${stateDir}/country.mmdb
        fi
        # Also provide the alternative name used by some mihomo versions.
        if [ ! -f ${stateDir}/geoip.metadb ]; then
          cp ${clashixLib.geodataFiles.mmdb} ${stateDir}/geoip.metadb
          chmod 644 ${stateDir}/geoip.metadb
        fi
        if [ ! -f ${stateDir}/geoip.dat ]; then
          cp ${clashixLib.geodataFiles.geoip} ${stateDir}/geoip.dat
          chmod 644 ${stateDir}/geoip.dat
        fi
        if [ ! -f ${stateDir}/geosite.dat ]; then
          cp ${clashixLib.geodataFiles.geosite} ${stateDir}/geosite.dat
          chmod 644 ${stateDir}/geosite.dat
        fi
      '';
    };

    # 2. Web dashboard (darkhttpd)
    systemd.services.clashix-dashboard = mkIf (cfg.dashboard.enable && cfg.dashboard.type != "none") {
      description = "Clashix Web Dashboard (darkhttpd)";
      after = [
        "network-online.target"
        "clashix.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress}";
        Restart = "on-failure";
        DynamicUser = true;
      };
    };

    # 3. Subscription update service + timer
    systemd.services.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      description = "Update Clashix subscriptions";
      after = [
        "network-online.target"
        "clashix.service"
      ];
      requires = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        # Secret is passed so the overlay includes it even for NixOS deployments
        ExecStart = "${clashixLib.mkUpdateScript cfg}/bin/clashix-update ${stateDir}/config.yaml ${cfg.secret}";
      };

      postStop = ''
        systemctl reload clashix.service || true
      '';
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
