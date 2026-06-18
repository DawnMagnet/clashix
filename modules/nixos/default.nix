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
  checkScript = clashixLib.mkConfigCheckScript cfg;

  # The directory where Mihomo stores run-time data and downloaded providers
  stateDir = "/var/lib/clashix";
  tunHealthCheckScript = clashixLib.mkTunHealthCheckScript cfg {
    inherit stateDir;
    isActiveCommand = "${pkgs.systemd}/bin/systemctl --quiet is-active clashix.service";
    restartCommand = "${pkgs.systemd}/bin/systemctl restart clashix.service";
  };

in
{
  options.programs.clashix = sharedOptions.options.programs.clashix;

  config = mkIf cfg.enable {

    # Dedicated system user — keeps the persistent runtime config owned by the
    # same account across preStart, subscription updates, and Mihomo itself.
    users.users.clashix = {
      isSystemUser = true;
      group = "clashix";
      description = "Clashix/Mihomo proxy daemon";
    };
    users.groups.clashix = { };

    # 1. Main Mihomo daemon
    systemd.services.clashix = {
      description = "Mihomo daemon (programs.clashix)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = "30s";
        StartLimitBurst = 5;
      };

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/mihomo -d ${stateDir} -f ${stateDir}/config.yaml";
        ExecStartPost = mkIf cfg.tun.enable "+${pkgs.writeShellScript "clashix-tun-check" ''
          if [ "$(cat ${stateDir}/.tun-safety-mode 2>/dev/null || true)" = "disabled" ]; then
            echo "TUN safety fallback is active; skipping TUN interface check"
            exit 0
          fi

          # Give mihomo time to initialize and attempt TUN setup
          sleep 3

          # Check if TUN interface exists.  Current Mihomo commonly uses Meta;
          # older/default setups may use utun or tun0.
          if ! ${pkgs.iproute2}/bin/ip link show Meta >/dev/null 2>&1 && ! ${pkgs.iproute2}/bin/ip link show utun >/dev/null 2>&1 && ! ${pkgs.iproute2}/bin/ip link show tun0 >/dev/null 2>&1; then
            echo "TUN interface not found after startup - will restart" >&2
            # Exit non-zero to mark service as failed, triggering Restart=on-failure
            exit 1
          fi
          echo "TUN interface detected successfully"
        ''}";
        ExecReload = "${pkgs.toybox}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "2s";
        StateDirectory = "clashix";
        StateDirectoryMode = "0700";
        DynamicUser = false;
        User = "clashix";
        Group = "clashix";
        PermissionsStartOnly = true;
      }
      // optionalAttrs cfg.tun.enable {
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
      };

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
        fix_runtime_permissions() {
          chown -R clashix:clashix ${stateDir}
          chmod 700 ${stateDir}
          if [ -f ${stateDir}/config.yaml ]; then
            chmod 600 ${stateDir}/config.yaml
          fi
          if [ -f ${stateDir}/config.yaml.last-good ]; then
            chmod 600 ${stateDir}/config.yaml.last-good
          fi
        }

        # Repair state left by older module versions or manual recovery.  This
        # must happen before any yq overlay attempts to rewrite config.yaml.
        fix_runtime_permissions

        # --- 1. Bootstrap config.yaml on first boot --------------------------------
        if [ ! -f ${stateDir}/config.yaml ]; then
          ${
            if cfg.bootstrapConfig != null then
              ''
                cp ${cfg.bootstrapConfig} ${stateDir}/config.yaml
                ${pkgs.coreutils}/bin/date +%s > ${stateDir}/.config-source-updated-at
              ''
            else if cfg.tun.enable && cfg.tun.safety.enable then
              ''
                echo "clashix: TUN safety refused first start without bootstrapConfig or existing ${stateDir}/config.yaml" >&2
                exit 1
              ''
            else
              ''
                cp ${configFile} ${stateDir}/config.yaml
                ${pkgs.coreutils}/bin/date +%s > ${stateDir}/.config-source-updated-at
              ''
          }
          chmod 600 ${stateDir}/config.yaml
          # Overlay Nix-controlled settings immediately so ports/controller are
          # correct from the very first start, regardless of what the seeded file
          # contained.
          ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
          # Record the generation marker so step 2 below is a no-op this boot.
          printf '%s' '${configFile}' > ${stateDir}/.nix-gen
        fi

        if [ ! -f ${stateDir}/.config-source-updated-at ]; then
          ${pkgs.coreutils}/bin/stat -c %Y ${stateDir}/config.yaml > ${stateDir}/.config-source-updated-at
        fi

        # --- 2. Re-apply overlay on generation change --------------------------------
        NIX_GEN_MARKER='${configFile}'
        if [ "$(cat ${stateDir}/.nix-gen 2>/dev/null)" != "$NIX_GEN_MARKER" ]; then
          ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
          printf '%s' "$NIX_GEN_MARKER" > ${stateDir}/.nix-gen
        fi

        ${
          optionalString (cfg.tun.enable && cfg.tun.safety.enable) ''
            # If a previous safety fallback removed TUN from the runtime config,
            # restore the declared settings before re-checking this start.
            ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
          ''
        }

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

        ${
          optionalString (cfg.tun.enable && cfg.tun.safety.enable) ''
            # --- 4. TUN safety gate --------------------------------------------------
            if ${checkScript}/bin/clashix-check-config ${stateDir} ${stateDir}/config.yaml; then
              rm -f ${stateDir}/.tun-safety-mode
            else
              ${
                if cfg.tun.safety.fallback == "disable-tun" then
                  ''
                    echo "clashix: TUN safety failed; starting Mihomo without TUN/DNS route takeover" >&2
                    safe_config=$(${pkgs.coreutils}/bin/mktemp)
                    cp ${stateDir}/config.yaml "$safe_config"
                    ${pkgs.yq-go}/bin/yq -i 'del(.tun) | del(.dns)' "$safe_config"
                    ${cfg.package}/bin/mihomo -t -d ${stateDir} -f "$safe_config" >/dev/null
                    cp "$safe_config" ${stateDir}/config.yaml
                    echo disabled > ${stateDir}/.tun-safety-mode
                    rm -f "$safe_config"
                  ''
                else
                  ''
                    echo "clashix: TUN safety failed; refusing to start" >&2
                    exit 1
                  ''
              }
            fi
          ''
        }

        fix_runtime_permissions
      '';
    };

    systemd.services.clashix-tun-health-check = mkIf (cfg.tun.enable && cfg.tun.healthCheck.enable) {
      description = "Check Clashix TUN health";
      after = [ "clashix.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tunHealthCheckScript}";
      };
    };

    systemd.timers.clashix-tun-health-check = mkIf (cfg.tun.enable && cfg.tun.healthCheck.enable) {
      description = "Timer to check Clashix TUN health";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.tun.healthCheck.interval;
        OnUnitActiveSec = cfg.tun.healthCheck.interval;
        AccuracySec = "5s";
        Unit = "clashix-tun-health-check.service";
      };
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
        ExecStart = "${pkgs.coreutils}/bin/env CLASHIX_CONFIG_OWNER=clashix:clashix ${clashixLib.mkUpdateScript cfg}/bin/clashix-update ${stateDir}/config.yaml ${cfg.secret}";
        ExecStartPost =
          if cfg.tun.enable then
            "${pkgs.systemd}/bin/systemctl try-restart clashix.service"
          else
            "${pkgs.systemd}/bin/systemctl try-reload-or-restart clashix.service";
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
