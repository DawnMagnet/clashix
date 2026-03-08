{ stdenvNoCC, fetchzip }:

stdenvNoCC.mkDerivation rec {
  pname = "zashboard";
  version = "v2.7.0";

  src = fetchzip {
    url = "https://github.com/Zephyruso/zashboard/releases/download/${version}/dist.zip";
    sha256 = "sha256-V3luGGR8xb88oLDMHQGQc0IhTZjRJ6RLe6fIBQ5W9Og=";
    stripRoot = false;
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/zashboard
    # dist.zip extracts to a dist/ subdirectory; copy its contents directly
    cp -r $src/dist/* $out/share/zashboard/

    runHook postInstall
  '';

  meta = {
    description = "Lightweight Dashboard for Clash/Mihomo";
    homepage = "https://github.com/Zephyruso/zashboard";
  };
}
