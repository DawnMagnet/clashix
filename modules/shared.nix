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
  };
}
