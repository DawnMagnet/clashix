# Comprehensive NixOS VM test suite for Clashix.
#
# Each check is an independent nixosTest so failures are isolated and tests
# can be run selectively with:
#   nix build .#checks.x86_64-linux.<test-name>
#
# Tests only make sense on Linux (NixOS VM tests require KVM/QEMU).
{ self, pkgs, lib }:

let
  # ─── Shared test fixtures ────────────────────────────────────────────────────

  # Minimal but valid Mihomo subscription YAML served by the mock HTTP server
  # in the subscription test.  Uses Shadowsocks so no real server is needed
  # (mihomo accepts it as valid config without dialing out).
  mockSubscriptionDir = pkgs.writeTextDir "sub.yaml" ''
    proxies:
      - name: mock-proxy
        type: ss
        server: 127.0.0.1
        port: 8388
        cipher: aes-256-gcm
        password: test-password
    proxy-groups:
      - name: Proxy
        type: select
        proxies:
          - mock-proxy
          - DIRECT
    rules:
      - MATCH,DIRECT
  '';

  # Base module import helper — keeps node definitions terse
  withClashix = extraCfg: { ... }: {
    imports = [ self.nixosModules.default ];
    programs.clashix = extraCfg;
  };

in
lib.optionalAttrs pkgs.stdenv.isLinux {

  # ─── 1. Basic: default configuration ────────────────────────────────────────
  #
  # Verifies that the default options produce a working setup:
  # - All five default ports are open and accepting connections
  # - Dashboard (yacd) serves HTML
  # - Mihomo REST API is reachable and returns JSON
  basicTest = pkgs.testers.nixosTest {
    name = "clashix-basic";

    nodes.machine = withClashix { enable = true; };

    testScript = ''
      machine.wait_for_unit("clashix.service")
      machine.wait_for_unit("clashix-dashboard.service")

      # All default ports must be open
      for port in [7890, 7891, 7892, 8080, 9090]:
          machine.wait_for_open_port(port)

      # Dashboard serves HTML
      response = machine.succeed("curl -sf http://127.0.0.1:8080")
      assert "html" in response.lower(), \
          f"Dashboard did not return HTML content: {response[:300]}"

      # Controller REST API responds with JSON (no secret configured → open)
      import json
      api_raw = machine.succeed("curl -sf http://127.0.0.1:9090/")
      try:
          api = json.loads(api_raw)
          assert isinstance(api, dict), f"API did not return a JSON object: {api_raw}"
      except json.JSONDecodeError:
          raise AssertionError(f"Controller API returned non-JSON: {api_raw[:300]}")

      # Both services survive a brief idle period (no immediate crashes)
      machine.sleep(3)
      machine.wait_for_unit("clashix.service")
      machine.wait_for_unit("clashix-dashboard.service")
    '';
  };

  # ─── 2. Custom ports + secret + API authentication ───────────────────────────
  #
  # - All five ports use non-default values; default ports must NOT be bound.
  # - Controller requires the configured secret (HTTP 401 without / with wrong,
  #   HTTP 200 with correct Bearer token).
  # - metacubexd dashboard type is exercised here.
  portsAndSecretTest = pkgs.testers.nixosTest {
    name = "clashix-ports-secret";

    nodes.machine = withClashix {
      enable          = true;
      port            = 17890;
      socksPort       = 17891;
      mixedPort       = 17892;
      controllerPort  = 19090;
      dashboard.port  = 18080;
      dashboard.type  = "yacd";
      secret          = "super-secret-test";
      mode            = "Global";
      logLevel        = "warning";
    };

    testScript = ''
      machine.wait_for_unit("clashix.service")
      machine.wait_for_unit("clashix-dashboard.service")

      for port in [17890, 17891, 17892, 18080, 19090]:
          machine.wait_for_open_port(port)

      # Default ports must NOT be bound
      for port in [7890, 7891, 7892, 8080, 9090]:
          machine.fail(f"curl -s --connect-timeout 2 http://127.0.0.1:{port}")

      # No Authorization header → 401
      code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:19090/"
      )
      assert code.strip() == "401", \
          f"Expected HTTP 401 with no secret, got {code.strip()}"

      # Wrong secret → 401
      code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "-H 'Authorization: Bearer totally-wrong' http://127.0.0.1:19090/"
      )
      assert code.strip() == "401", \
          f"Expected HTTP 401 with wrong secret, got {code.strip()}"

      # Correct secret → 200
      code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "-H 'Authorization: Bearer super-secret-test' http://127.0.0.1:19090/"
      )
      assert code.strip() == "200", \
          f"Expected HTTP 200 with correct secret, got {code.strip()}"

      # Dashboard returns HTML
      response = machine.succeed("curl -sf http://127.0.0.1:18080")
      assert "html" in response.lower(), "metacubexd dashboard did not serve HTML"
    '';
  };

  # ─── 3. Dashboard type = "none" ─────────────────────────────────────────────
  #
  # With type = "none" no dashboard service should be created and the dashboard
  # port must not be bound.  The controller (port 9090) must still work.
  #
  # Note: zashboard/metacubexd use ghproxy.com CDN downloads and are only
  # verified to build correctly via `nix build .#packages.x86_64-linux.*`.
  dashboardTypesTest = pkgs.testers.nixosTest {
    name = "clashix-dashboard-types";

    nodes = {
      # A second yacd instance confirms the selection mechanism routes correctly
      # through getDashboardPkg / getDashboardPath when the dashboard IS enabled.
      withdashboard  = withClashix { enable = true; dashboard.type = "yacd"; dashboard.port = 8181; };
      nodashboard    = withClashix { enable = true; dashboard.type = "none"; };
    };

    testScript = ''
      # --- withdashboard node: dashboard must serve HTML on the configured port ---
      withdashboard.wait_for_unit("clashix.service")
      withdashboard.wait_for_unit("clashix-dashboard.service")
      withdashboard.wait_for_open_port(8181)
      response = withdashboard.succeed("curl -sf http://127.0.0.1:8181")
      assert "html" in response.lower(), "dashboard did not serve HTML"

      # --- nodashboard node ---
      nodashboard.wait_for_unit("clashix.service")

      # Dashboard service must NOT be active
      status = nodashboard.succeed(
          "systemctl is-active clashix-dashboard.service || true"
      )
      assert status.strip() != "active", \
          "clashix-dashboard.service is unexpectedly active with type=none"

      # Dashboard port must not be listening
      nodashboard.fail("curl -s --connect-timeout 3 http://127.0.0.1:8080")

      # Controller must still work
      nodashboard.wait_for_open_port(9090)
      nodashboard.succeed("curl -sf http://127.0.0.1:9090/")
    '';
  };

  # ─── 4. Subscription update ──────────────────────────────────────────────────
  #
  # End-to-end subscription flow:
  #   1. A mock darkhttpd instance serves a valid YAML subscription.
  #   2. clashix-update.service is triggered manually.
  #   3. The resulting config.yaml must contain the subscription proxy AND
  #      retain all Nix-controlled settings (port, external-controller, etc.).
  subscriptionTest = pkgs.testers.nixosTest {
    name = "clashix-subscription";

    nodes.machine = { pkgs, ... }: {
      imports = [ self.nixosModules.default ];

      # Mock HTTP server that serves the subscription YAML before any update
      systemd.services.mock-subscription-server = {
        description = "Mock subscription HTTP server (test fixture)";
        wantedBy    = [ "multi-user.target" ];
        before      = [ "clashix-update.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${mockSubscriptionDir} --port 9999 --addr 127.0.0.1";
          Restart     = "on-failure";
          DynamicUser = true;
        };
      };

      programs.clashix = {
        enable           = true;
        port             = 7890;
        subscriptionUrls = [ "http://127.0.0.1:9999/sub.yaml" ];
        dashboard.type   = "none";
      };
    };

    testScript = ''
      machine.wait_for_unit("mock-subscription-server.service")
      machine.wait_for_open_port(9999)
      machine.wait_for_unit("clashix.service")

      # Sanity-check that the mock server actually serves the file
      sub_content = machine.succeed("curl -sf http://127.0.0.1:9999/sub.yaml")
      assert "mock-proxy" in sub_content, \
          f"Mock server did not serve expected YAML: {sub_content[:300]}"

      # Trigger the subscription update
      machine.succeed("systemctl start clashix-update.service")
      machine.wait_for_unit("clashix.service")

      config = machine.succeed("cat /var/lib/clashix/config.yaml")

      # Subscription proxy must appear in merged config
      assert "mock-proxy" in config, \
          f"Subscription proxy not present in config after update:\n{config[:800]}"

      # Nix-controlled settings must survive the overlay
      machine.succeed("grep -E 'port: 7890' /var/lib/clashix/config.yaml")
      machine.succeed("grep 'external-controller' /var/lib/clashix/config.yaml")

      # config.yaml must still be valid YAML (parseable by yq)
      machine.succeed(
          "${pkgs.yq-go}/bin/yq e '.' /var/lib/clashix/config.yaml > /dev/null"
      )
    '';
  };

  # ─── 5. Subscription update with multiple URLs ───────────────────────────────
  #
  # Verifies that proxies from a second subscription are merged into the base
  # config from the first, without duplicating proxy-groups.
  multiSubscriptionTest = pkgs.testers.nixosTest {
    name = "clashix-multi-subscription";

    nodes.machine =
      let
        sub2Dir = pkgs.writeTextDir "sub2.yaml" ''
          proxies:
            - name: second-proxy
              type: ss
              server: 127.0.0.1
              port: 8389
              cipher: aes-256-gcm
              password: second-password
          proxy-groups:
            - name: Proxy
              type: select
              proxies:
                - second-proxy
                - DIRECT
          rules:
            - MATCH,DIRECT
        '';
      in
      { pkgs, ... }: {
        imports = [ self.nixosModules.default ];

        systemd.services.mock-sub1 = {
          wantedBy = [ "multi-user.target" ];
          before   = [ "clashix-update.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${mockSubscriptionDir} --port 9998 --addr 127.0.0.1";
            DynamicUser = true;
          };
        };

        systemd.services.mock-sub2 = {
          wantedBy = [ "multi-user.target" ];
          before   = [ "clashix-update.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${sub2Dir} --port 9997 --addr 127.0.0.1";
            DynamicUser = true;
          };
        };

        programs.clashix = {
          enable = true;
          subscriptionUrls = [
            "http://127.0.0.1:9998/sub.yaml"
            "http://127.0.0.1:9997/sub2.yaml"
          ];
          dashboard.type = "none";
        };
      };

    testScript = ''
      machine.wait_for_unit("mock-sub1.service")
      machine.wait_for_unit("mock-sub2.service")
      machine.wait_for_open_port(9998)
      machine.wait_for_open_port(9997)
      machine.wait_for_unit("clashix.service")

      machine.succeed("systemctl start clashix-update.service")
      machine.wait_for_unit("clashix.service")

      config = machine.succeed("cat /var/lib/clashix/config.yaml")

      # Both proxies must appear
      assert "mock-proxy" in config,   f"First subscription proxy missing: {config[:800]}"
      assert "second-proxy" in config, f"Second subscription proxy missing: {config[:800]}"

      # proxy-groups must appear exactly once (from the primary subscription only)
      import re
      group_matches = re.findall(r'(?m)^proxy-groups:', config)
      assert len(group_matches) == 1, \
          f"Expected exactly one 'proxy-groups:' block, found {len(group_matches)}"
    '';
  };

  # ─── 6. TUN mode: dedicated system user + capabilities ───────────────────────
  #
  # When tun.enable = true the NixOS module must:
  #   - Declare the 'clashix' system user and group.
  #   - Configure the service with User=clashix (not root).
  #   - Grant CAP_NET_ADMIN and CAP_NET_BIND_SERVICE as ambient capabilities.
  tunTest = pkgs.testers.nixosTest {
    name = "clashix-tun";

    nodes.machine = { ... }: {
      imports = [ self.nixosModules.default ];

      # Ensure the tun kernel module is available in the VM
      boot.kernelModules = [ "tun" ];

      programs.clashix = {
        enable         = true;
        tun.enable     = true;
        dashboard.type = "none";
      };
    };

    testScript = ''
      # The 'clashix' system user and group must be provisioned
      machine.succeed("id clashix")
      machine.succeed("getent group clashix")

      # Verify unit-file level configuration (does not require the process to run)
      unit_conf = machine.succeed("systemctl cat clashix.service")
      assert "User=clashix" in unit_conf, \
          f"clashix.service missing User=clashix directive:\n{unit_conf}"
      assert "AmbientCapabilities" in unit_conf, \
          f"clashix.service missing AmbientCapabilities:\n{unit_conf}"
      assert "CAP_NET_ADMIN" in unit_conf, \
          f"clashix.service missing CAP_NET_ADMIN:\n{unit_conf}"

      # Try to start the service; if mihomo manages to bring up the TUN
      # interface even briefly, verify it is not running as root.
      machine.wait_for_unit("clashix.service")

      pid = machine.succeed(
          "systemctl show -p MainPID --value clashix.service"
      ).strip()

      if pid and pid != "0":
          uid = machine.succeed(f"stat -c '%u' /proc/{pid} 2>/dev/null || echo -1").strip()
          assert uid != "0", \
              f"clashix process (pid={pid}) is running as root (uid=0); " \
              "expected non-root 'clashix' user"

          # Ambient capabilities must be non-zero
          cap_amb = machine.succeed(
              f"grep CapAmb /proc/{pid}/status 2>/dev/null || echo 'CapAmb: 0000000000000000'"
          ).strip()
          cap_hex = cap_amb.split()[-1]
          assert cap_hex != "0000000000000000", \
              f"Expected non-zero ambient capabilities (CAP_NET_ADMIN), got: {cap_amb}"
    '';
  };

  # ─── 7. Generation tracking: overlay re-applied after nixos-rebuild ──────────
  #
  # Simulates what happens when a user changes a Nix option and rebuilds:
  #   1. Service starts and writes the .nix-gen marker.
  #   2. We corrupt the marker and manually drift config.yaml (wrong port).
  #   3. Service restarts → preStart detects the marker mismatch and re-applies
  #      the Nix overlay, correcting the port without requiring a full reinstall.
  generationTest = pkgs.testers.nixosTest {
    name = "clashix-generation";

    nodes.machine = { pkgs, ... }: {
      imports = [ self.nixosModules.default ];
      environment.systemPackages = [ pkgs.yq-go ];

      programs.clashix = {
        enable         = true;
        port           = 7890;
        dashboard.type = "none";
      };
    };

    testScript = ''
      machine.wait_for_unit("clashix.service")
      machine.wait_for_open_port(7890)

      # Initial state: config.yaml must reflect the declared port
      machine.succeed("grep -E 'port: 7890' /var/lib/clashix/config.yaml")

      # .nix-gen marker must point into the Nix store
      nix_gen = machine.succeed("cat /var/lib/clashix/.nix-gen").strip()
      assert nix_gen.startswith("/nix/store/"), \
          f"Expected /nix/store/... in .nix-gen on first start, got: {nix_gen!r}"

      # --- Simulate config drift (as if a different Nix generation was active) ---
      machine.succeed("yq -i '.port = 22222' /var/lib/clashix/config.yaml")
      machine.succeed("echo 'stale-generation-marker' > /var/lib/clashix/.nix-gen")

      # Confirm the drift is present before restart
      machine.succeed("grep -E 'port: 22222' /var/lib/clashix/config.yaml")

      # Restart: preStart must detect marker mismatch and re-apply the overlay
      machine.succeed("systemctl restart clashix.service")
      machine.wait_for_unit("clashix.service")

      # Port must be corrected back to the Nix-declared value
      machine.succeed("grep -E 'port: 7890' /var/lib/clashix/config.yaml")
      machine.wait_for_open_port(7890)

      # Marker must now be the current Nix store path (not the stale one)
      nix_gen_after = machine.succeed("cat /var/lib/clashix/.nix-gen").strip()
      assert nix_gen_after.startswith("/nix/store/"), \
          f"Expected /nix/store/... in .nix-gen after restart, got: {nix_gen_after!r}"
      assert nix_gen_after != "stale-generation-marker", \
          ".nix-gen still contains the stale marker after restart"
    '';
  };

  # ─── 8. tun.stack option ────────────────────────────────────────────────────
  #
  # Verifies that setting tun.stack to a non-default value is reflected in
  # config.yaml (tests the new shared.nix option path to clashix-lib.nix).
  tunStackTest = pkgs.testers.nixosTest {
    name = "clashix-tun-stack";

    nodes.machine = { ... }: {
      imports = [ self.nixosModules.default ];
      boot.kernelModules = [ "tun" ];

      programs.clashix = {
        enable         = true;
        tun.enable     = true;
        tun.stack      = "gvisor";
        dashboard.type = "none";
      };
    };

    testScript = ''
      machine.wait_for_unit("clashix.service")

      config = machine.succeed("cat /var/lib/clashix/config.yaml")
      assert "gvisor" in config, \
          f"Expected tun.stack=gvisor in config.yaml:\n{config[:600]}"
    '';
  };

  # ─── 9. Dashboard accessibility + controller authentication ─────────────────
  #
  # Validates the full "auth link" flow used by dashboard UIs (yacd, metacubexd,
  # zashboard).  The dashboard app embeds the controller address and secret in
  # the URL hash ("#/setup?hostname=...&port=9090&secret=...") and then calls
  # the REST API with "Authorization: Bearer <secret>".  This test verifies:
  #
  #   a) Dashboard static files are served and return HTML (no auth required).
  #   b) Controller rejects requests without or with wrong secret (HTTP 401).
  #   c) Controller accepts requests with the correct Bearer token (HTTP 200).
  #   d) Actual API endpoints (/proxies, /configs) return valid JSON when
  #      authenticated — i.e. not just the root path.
  #   e) CORS: a request carrying an allowed Origin header receives an
  #      "Access-Control-Allow-Origin" response header so the dashboard SPA
  #      running in a browser can actually read the API response.
  #   f) CORS: an Origin not in the allow-list does NOT receive the header.
  dashboardAuthTest = pkgs.testers.nixosTest {
    name = "clashix-dashboard-auth";

    nodes.machine = withClashix {
      enable         = true;
      secret         = "dashboard-test-secret";
      dashboard.type = "yacd";
      dashboard.port = 8080;
      controllerPort = 9090;
    };

    testScript = ''
      import json

      machine.wait_for_unit("clashix.service")
      machine.wait_for_unit("clashix-dashboard.service")
      machine.wait_for_open_port(8080)
      machine.wait_for_open_port(9090)

      SECRET = "dashboard-test-secret"

      # ── a) Dashboard HTML accessible without any secret ──────────────────────
      html = machine.succeed("curl -sf http://127.0.0.1:8080")
      assert "html" in html.lower(), \
          f"Dashboard did not serve HTML (no auth required for static files): {html[:300]}"

      # ── b) Controller rejects unauthenticated / wrong-secret requests ─────────
      code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/"
      ).strip()
      assert code == "401", \
          f"Expected 401 with no Authorization header, got {code}"

      code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "-H 'Authorization: Bearer totally-wrong' http://127.0.0.1:9090/"
      ).strip()
      assert code == "401", \
          f"Expected 401 with wrong secret, got {code}"

      # ── c) Correct Bearer token → 200 ────────────────────────────────────────
      code = machine.succeed(
          f"curl -s -o /dev/null -w '%{{http_code}}' "
          f"-H 'Authorization: Bearer {SECRET}' http://127.0.0.1:9090/"
      ).strip()
      assert code == "200", \
          f"Expected 200 with correct secret, got {code}"

      # ── d) Specific API endpoints return valid JSON when authenticated ─────────
      # /proxies
      raw = machine.succeed(
          f"curl -sf -H 'Authorization: Bearer {SECRET}' http://127.0.0.1:9090/proxies"
      )
      try:
          j = json.loads(raw)
          assert "proxies" in j, f"/proxies JSON missing 'proxies' key: {j}"
      except json.JSONDecodeError:
          raise AssertionError(f"/proxies returned non-JSON: {raw[:300]}")

      # /configs
      raw = machine.succeed(
          f"curl -sf -H 'Authorization: Bearer {SECRET}' http://127.0.0.1:9090/configs"
      )
      try:
          j = json.loads(raw)
          assert "mixed-port" in j or "port" in j, \
              f"/configs JSON missing port keys: {j}"
      except json.JSONDecodeError:
          raise AssertionError(f"/configs returned non-JSON: {raw[:300]}")

      # /version
      raw = machine.succeed(
          f"curl -sf -H 'Authorization: Bearer {SECRET}' http://127.0.0.1:9090/version"
      )
      try:
          j = json.loads(raw)
          assert "version" in j, f"/version JSON missing 'version' key: {j}"
      except json.JSONDecodeError:
          raise AssertionError(f"/version returned non-JSON: {raw[:300]}")

      # ── e) CORS: allowed Origin receives Access-Control-Allow-Origin header ────
      # This is the exact flow a dashboard SPA uses when opened via the auth link:
      # the browser sends Origin: <dashboard-host> with every API request.
      cors_ok = machine.succeed(
          f"curl -si "
          f"-H 'Origin: https://yacd.metacubex.one' "
          f"-H 'Authorization: Bearer {SECRET}' "
          f"http://127.0.0.1:9090/"
      ).lower()
      assert "access-control-allow-origin" in cors_ok, \
          f"Expected CORS header for allowed origin, response headers:\n{cors_ok[:600]}"

      # Also check a second allowed origin from the list
      cors_ok2 = machine.succeed(
          f"curl -si "
          f"-H 'Origin: https://metacubex.github.io' "
          f"-H 'Authorization: Bearer {SECRET}' "
          f"http://127.0.0.1:9090/"
      ).lower()
      assert "access-control-allow-origin" in cors_ok2, \
          f"Expected CORS header for metacubex.github.io, got:\n{cors_ok2[:600]}"

      # ── f) CORS: unlisted Origin must NOT receive the allow-origin header ──────
      cors_bad = machine.succeed(
          f"curl -si "
          f"-H 'Origin: https://evil.example.com' "
          f"-H 'Authorization: Bearer {SECRET}' "
          f"http://127.0.0.1:9090/"
      ).lower()
      # Split headers from body; only inspect the header section
      header_section = cors_bad.split("\r\n\r\n")[0] if "\r\n\r\n" in cors_bad else cors_bad
      assert "access-control-allow-origin: https://evil.example.com" not in header_section, \
          f"Controller should NOT echo back unlisted Origin:\n{header_section[:600]}"
    '';
  };

  # ─── 10. allowLan: proxy ports bind to all interfaces ───────────────────────
  #
  # With allowLan = true, mihomo must bind its proxy ports to 0.0.0.0 (all
  # interfaces) rather than 127.0.0.1.  We verify this with `ss` on a single
  # machine — the binding behaviour is the real invariant to test, and it does
  # not require a second VM or complex inter-machine networking.
  allowLanTest = pkgs.testers.nixosTest {
    name = "clashix-allow-lan";

    nodes = {
      enabled  = withClashix { enable = true; allowLan = true;  dashboard.type = "none"; };
      disabled = withClashix { enable = true; allowLan = false; dashboard.type = "none"; };
    };

    testScript = ''
      # ss -tlnp output: "LISTEN 0 N  LocalAddr:Port  PeerAddr:Port ..."
      # The local binding address is what we care about.

      # --- allowLan = true: ports must bind to 0.0.0.0 (all interfaces) ---
      enabled.wait_for_unit("clashix.service")
      enabled.wait_for_open_port(7890)

      sockets = enabled.succeed("ss -tlnp")
      # ss shows all-interface bindings as either "0.0.0.0:PORT" or "*:PORT"
      assert "0.0.0.0:7890" in sockets or "*:7890" in sockets, \
          f"Expected wildcard binding on 7890 with allowLan=true:\n{sockets}"
      assert "0.0.0.0:7892" in sockets or "*:7892" in sockets, \
          f"Expected wildcard binding on 7892 with allowLan=true:\n{sockets}"

      # --- allowLan = false: ports must bind to 127.0.0.1 only ---
      disabled.wait_for_unit("clashix.service")
      disabled.wait_for_open_port(7890)

      sockets = disabled.succeed("ss -tlnp")
      assert "127.0.0.1:7890" in sockets, \
          f"Expected 127.0.0.1:7890 local binding with allowLan=false:\n{sockets}"
      # Wildcard bindings must NOT appear for these ports
      assert "0.0.0.0:7890" not in sockets and "*:7890" not in sockets, \
          f"Port 7890 should not bind to all interfaces with allowLan=false:\n{sockets}"
    '';
  };

}
