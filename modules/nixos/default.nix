{ config
, lib
, pkgs
, ...
}:

with lib;

let
  cfg = config.programs.clashix;

  # Import options, passing isHomeManager = false
  sharedOptions = import ../shared.nix {
    inherit lib pkgs config;
    isHomeManager = false;
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
  // (optionalAttrs (cfg.dashboard.enable && dashboardPkg != null) {
    external-ui = dashboardPath;
  })
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
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
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
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${dashboardPath} --port ${toString cfg.dashboard.port} --addr ${cfg.dashboard.bindAddress}";
        Restart = "on-failure";
        DynamicUser = true;
      };
    };

    # 2. Provide the Subscription Update Timer and Service
    systemd.services.clashix-update = mkIf (cfg.subscriptionUrl != null) {
      description = "Update Clashix Subscription";
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];

      path = [
        pkgs.curl
        pkgs.yq
      ];

      script = ''
        echo "Updating subscription from ${cfg.subscriptionUrl}..."
        # Download subscription securely to a temp file
        temp_file=$(mktemp)
        curl -sL --retry 3 "${cfg.subscriptionUrl}" -o "$temp_file"

        if [ $? -eq 0 ]; then
          # We update the main config.yaml but keep our base settings.
          # Here we just blindly overwrite and append our required base settings.
          # For a real module, a user might use `proxy-providers` in `extraConfig` instead of downloading the full config.
          # We'll merge the downloaded config with our base config to ensure the dashboard remains accessible.

          # Use yq to merge our declarative parts (external-controller, ui) back into the downloaded config
          yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$temp_file" "${configFile}" > ${stateDir}/config.yaml.new

          mv ${stateDir}/config.yaml.new ${stateDir}/config.yaml
          rm -f "$temp_file"

          echo "Reloading clashix service..."
          systemctl reload clashix.service
        else
          echo "Failed to download subscription."
          rm -f "$temp_file"
          exit 1
        fi
      '';

      serviceConfig = {
        Type = "oneshot";
        # We need root or the same permissions as the state directory
      };
    };

    systemd.timers.clashix-update = mkIf (cfg.subscriptionUrl != null) {
      description = "Timer to update Clashix subscription";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.updateInterval;
        Persistent = true;
      };
    };

  };
}
