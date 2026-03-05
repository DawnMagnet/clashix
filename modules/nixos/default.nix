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

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${clashixLib.mkUpdateScript cfg}/bin/clashix-update ${stateDir}/config.yaml";
      };

      postStop = ''
        echo "Reloading clashix service..."
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
