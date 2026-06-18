{ lib, pkgs, ... }:

with lib;
{
  options.programs.clashix = {
    enable = mkEnableOption "Clashix, a declarative Mihomo client with integrated dashboard";

    package = mkOption {
      type = types.package;
      default = pkgs.mihomo;
      defaultText = literalExpression "pkgs.mihomo";
      description = "The Mihomo package to use.";
    };

    subscriptionUrls = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "https://example.com/sub1"
        "https://example.com/sub2"
      ];
      description = ''
        A list of clash/mihomo subscription URLs.
        If any are provided, a systemd timer will continuously fetch and merge them into the active configuration.
      '';
    };

    updateInterval = mkOption {
      type = types.str;
      default = "daily";
      description = ''
        systemd calendar expression or interval for the subscription update timer.
        Examples: "daily", "*-*-* 04:00:00", "every 6 hours".
      '';
    };

    tun = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable TUN mode for transparent proxying.";
      };

      stack = mkOption {
        type = types.enum [
          "system"
          "gvisor"
          "mixed"
        ];
        default = "system";
        description = ''
          TUN stack implementation.
          - "system": uses the kernel network stack (lowest overhead, recommended)
          - "gvisor": uses the gVisor userspace stack (better isolation)
          - "mixed": system stack for TCP, gVisor for UDP
        '';
      };

      safety = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Enable a startup safety gate for TUN mode.  When enabled, Clashix
            refuses to start TUN from an empty first-boot skeleton, validates
            the active Mihomo configuration before route takeover, and can
            fall back to non-TUN mode when the configuration is invalid or too
            old.
          '';
        };

        maxConfigAgeDays = mkOption {
          type = types.ints.unsigned;
          default = 7;
          description = ''
            Maximum accepted age, in days, of the last successful bootstrap or
            subscription update before TUN is considered unsafe.  Set to 0 to
            disable the age check.
          '';
        };

        fallback = mkOption {
          type = types.enum [
            "disable-tun"
            "stop"
          ];
          default = "disable-tun";
          description = ''
            What to do when the TUN safety gate fails.  "disable-tun" starts
            Mihomo with TUN/DNS removed from the runtime config; "stop" refuses
            to start the service.
          '';
        };
      };

      healthCheck = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Enable a periodic runtime health check for TUN mode.  The check
            restarts the Clashix service when the TUN interface or its default
            route disappears while Mihomo is still running.
          '';
        };

        interval = mkOption {
          type = types.str;
          default = "30s";
          description = ''
            systemd time span used between TUN health checks.
          '';
        };

        requireDefaultRoute = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Require a default route through the detected TUN interface.  Disable
            this only for unusual Mihomo routing setups that intentionally keep
            TUN routes out of system routing tables.
          '';
        };
      };
    };

    dashboard = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable serving a web dashboard via darkhttpd.";
      };

      type = mkOption {
        type = types.enum [
          "none"
          "yacd"
          "metacubexd"
          "zashboard"
        ];
        default = "yacd";
        description = "Which dashboard to use. Select 'none' to disable the dashboard UI.";
      };

      port = mkOption {
        type = types.port;
        default = 8080;
        description = "The port for the darkhttpd dashboard web server.";
      };

      bindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "The bind address for the darkhttpd web server and the external controller.";
      };
    };

    port = mkOption {
      type = types.port;
      default = 7890;
      description = "HTTP proxy port.";
    };

    socksPort = mkOption {
      type = types.port;
      default = 7891;
      description = "SOCKS5 proxy port.";
    };

    mixedPort = mkOption {
      type = types.port;
      default = 7892;
      description = "Mixed (HTTP+SOCKS5) proxy port.";
    };

    controllerPort = mkOption {
      type = types.port;
      default = 9090;
      description = "The port for the external controller (RESTful API).";
    };

    secret = mkOption {
      type = types.str;
      default = "";
      description = ''
        Secret for the external controller API.
        Leave empty to auto-generate a random secret at runtime (shell mode only).
        For NixOS/Home Manager deployments, set an explicit secret or manage it
        via a secrets manager (e.g. sops-nix, agenix) and pass the value here.
      '';
    };

    allowLan = mkOption {
      type = types.bool;
      default = false;
      description = "Allow other devices to connect to the proxy and controller.";
    };

    mode = mkOption {
      type = types.enum [
        "Rule"
        "Global"
        "Direct"
      ];
      default = "Rule";
      description = "Mihomo proxy mode.";
    };

    logLevel = mkOption {
      type = types.enum [
        "info"
        "warning"
        "error"
        "debug"
        "silent"
      ];
      default = "info";
      description = "Mihomo log level.";
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = { };
      description = "Extra verbatim Mihomo configuration to merge into the generated config.yaml.";
    };

    bootstrapConfig = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression ''
        pkgs.fetchurl {
          url  = "https://example.com/my-subscription";
          sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        }
      '';
      description = ''
        An optional path (or fixed-output <literal>pkgs.fetchurl</literal>
        derivation) to use as the initial <filename>config.yaml</filename> on
        first boot, instead of the minimal Nix-generated skeleton.

        This solves the chicken-and-egg problem where the machine needs a
        working proxy config to reach the internet in order to fetch its own
        subscription.  Supply a pre-fetched snapshot here (built into the
        system closure at <command>nixos-rebuild</command> time) so the proxy
        is usable from the very first boot.

        All Nix-controlled settings (ports, controller address, secret, …) are
        overlaid on top of the file after it is copied, so you do not need to
        keep those in sync manually.

        On subsequent boots the file is left untouched; the subscription timer
        will refresh it as usual.
      '';
    };
  };
}
