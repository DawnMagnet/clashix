{ stdenvNoCC, fetchzip }:

stdenvNoCC.mkDerivation rec {
  pname = "zashboard";
  version = "v3.5.1";

  src = fetchzip {
    url = "https://github.com/Zephyruso/zashboard/releases/download/${version}/dist.zip";
    sha256 = "sha256-QE0LZlptAA6e1wAE+1NMC+HIoTGAmbQM4Ps1FM03a1k=";
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
