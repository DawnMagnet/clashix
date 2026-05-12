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

  # yq overlay expression shared with activation script
  overlayExpr = clashixLib.mkOverlayExpr cfg;
  checkScript = clashixLib.mkConfigCheckScript cfg;

  # stateDir for Home Manager: follows XDG state convention
  stateDir = "${config.xdg.stateHome}/clashix";

in
{
  options.programs.clashix = sharedOptions.options.programs.clashix;

  config = mkIf cfg.enable {

    # Warn only when TUN is actually requested — an empty string in warnings
    # can silently produce a spurious blank warning entry.
    warnings = optional cfg.tun.enable ''
      Clashix TUN mode is enabled within Home Manager.
      Since user services lack 'CAP_NET_ADMIN' capabilities by default, Mihomo
      will likely crash when starting TUN.
      Use the NixOS module instead, or wrap the binary with:
        sudo setcap 'cap_net_admin,cap_net_bind_service=+ep' $(readlink -f ${cfg.package}/bin/mihomo)
    '';

    # Generation-aware initialisation (mirrors the NixOS preStart logic).
    # 1. Bootstrap config.yaml from bootstrapConfig (if set) or the generated
    #    skeleton on first activation, overlaying Nix settings immediately.
    # 2. Re-apply overlay on every generation change.
    # 3. Pre-populate geodata from the Nix store so mihomo never needs to
    #    download the files at runtime.
    home.activation.setupClashixConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${stateDir}

      # --- 1. Bootstrap config.yaml on first activation -------------------------
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
        ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
        printf '%s' '${configFile}' > ${stateDir}/.nix-gen
      fi

      if [ ! -f ${stateDir}/.config-source-updated-at ]; then
        ${pkgs.coreutils}/bin/stat -c %Y ${stateDir}/config.yaml > ${stateDir}/.config-source-updated-at
      fi

      # --- 2. Re-apply overlay on generation change -----------------------------
      NIX_GEN_MARKER='${configFile}'
      if [ "$(cat ${stateDir}/.nix-gen 2>/dev/null)" != "$NIX_GEN_MARKER" ]; then
        ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
        printf '%s' "$NIX_GEN_MARKER" > ${stateDir}/.nix-gen
      fi

      ${
        optionalString (cfg.tun.enable && cfg.tun.safety.enable) ''
          ${pkgs.yq-go}/bin/yq -i '${overlayExpr}' ${stateDir}/config.yaml
        ''
      }

      # --- 3. Seed geodata from the Nix store -----------------------------------
      if [ ! -f ${stateDir}/country.mmdb ]; then
        cp ${clashixLib.geodataFiles.mmdb} ${stateDir}/country.mmdb
        chmod 644 ${stateDir}/country.mmdb
      fi
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
    '';

    # 1. Main Mihomo user service
    systemd.user.services.clashix = {
      Unit = {
        Description = "Mihomo daemon (programs.clashix via Home Manager)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        StartLimitIntervalSec = "30s";
        StartLimitBurst = 5;
      };

      Install.WantedBy = [ "default.target" ];

      Service = {
        ExecStart = "${cfg.package}/bin/mihomo -d ${stateDir} -f ${stateDir}/config.yaml";
        ExecReload = "${pkgs.toybox}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "2s";
        # Note: TUN mode under user services is problematic — see warnings above.
        # TUN health check only works if user has sufficient privileges (setcap)
        ExecStartPost = mkIf cfg.tun.enable (pkgs.writeShellScript "clashix-tun-check-hm" ''
          if [ "$(cat ${stateDir}/.tun-safety-mode 2>/dev/null || true)" = "disabled" ]; then
            echo "TUN safety fallback is active; skipping TUN interface check"
            exit 0
          fi

          sleep 3
          if ! ${pkgs.iproute2}/bin/ip link show Meta >/dev/null 2>&1 && ! ${pkgs.iproute2}/bin/ip link show utun >/dev/null 2>&1 && ! ${pkgs.iproute2}/bin/ip link show tun0 >/dev/null 2>&1; then
            echo "TUN interface not found after startup - will restart" >&2
            exit 1
          fi
          echo "TUN interface detected successfully"
        '');
      };
    };

    # 2. Web dashboard (darkhttpd)
    systemd.user.services.clashix-dashboard =
      mkIf (cfg.dashboard.enable && cfg.dashboard.type != "none")
        {
          Unit = {
            Description = "Clashix Web Dashboard (darkhttpd, user)";
            After = [
              "network-online.target"
              "clashix.service"
            ];
            Wants = [ "network-online.target" ];
          };

          Install.WantedBy = [ "default.target" ];

          Service = {
            ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress}";
            Restart = "on-failure";
          };
        };

    # 3. Subscription update service + timer
    systemd.user.services.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      Unit = {
        Description = "Update Clashix subscriptions (user)";
        After = [
          "network-online.target"
          "clashix.service"
        ];
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${clashixLib.mkUpdateScript cfg}/bin/clashix-update ${stateDir}/config.yaml ${cfg.secret}";
        ExecStopPost = pkgs.writeShellScript "clashix-post-update-hm" ''
          ${pkgs.systemd}/bin/systemctl --user reload clashix.service || true
        '';
      };
    };

    systemd.user.timers.clashix-update = mkIf (cfg.subscriptionUrls != [ ]) {
      Unit.Description = "Timer to update Clashix subscriptions (user)";

      Timer = {
        OnCalendar = cfg.updateInterval;
        Persistent = true;
      };

      Install.WantedBy = [ "timers.target" ];
    };

  };
}
