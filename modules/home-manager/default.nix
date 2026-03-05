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

  clashixLib = import ../clashix-lib.nix { inherit lib pkgs; };

  dashboardPath = clashixLib.getDashboardPath cfg;

  # Base generated configuration
  finalConfig = clashixLib.mkClashConfig cfg;

  configFile = pkgs.writeText "clashix-config.yaml" (builtins.toJSON finalConfig);

  # stateDir for Home Manager (typically ~/.config/clashix or ~/.local/state/clashix)
  # We use the XDG state home
  stateDir = "${config.xdg.stateHome}/clashix";

  # Warning for HM users trying to use TUN
  tunWarning = lib.optionalString cfg.tun.enable ''
    Clashix TUN mode is enabled within Home Manager.
    Since user services lack 'CAP_NET_ADMIN' capabilities by default, Mihomo will likely crash when starting TUN.
    It is highly recommended to use the NixOS module for TUN mode instead.
  '';

in
{
  options.programs.clashix = sharedOptions.options.programs.clashix;

  config = mkIf cfg.enable {
    warnings = [ tunWarning ];

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
        ExecReload = "${pkgs.toybox}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        # Note: TUN mode under User Services is generally problematic without wrappers or CAP_NET_ADMIN.
        # See the warnings generated when tun.enable = true.
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
        ExecStart = "${clashixLib.mkUpdateScript cfg}/bin/clashix-update ${stateDir}/config.yaml";
        ExecStopPost = pkgs.writeShellScript "clashix-post-update-hm" ''
          echo "Reloading user clashix service..."
          ${pkgs.systemd}/bin/systemctl --user reload clashix.service || true
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
