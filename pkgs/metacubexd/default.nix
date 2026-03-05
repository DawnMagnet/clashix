{ stdenvNoCC, fetchzip }:

# metacubexd: Official dashboard from MetaCubeX
stdenvNoCC.mkDerivation rec {
  pname = "metacubexd";
  version = "v1.241.3"; # Latest version as of writing

  src = fetchzip {
    # REAL
    url = "https://mirror.ghproxy.com/https://github.com/MetaCubeX/metacubexd/releases/download/${version}/compressed-dist.tgz";
    sha256 = "1bmpzyy7m1736inckz3v7lhx4nac4pa9p113j1jvs9aspwpw8q6i";
    stripRoot = false;
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/metacubexd
    cp -r $src/* $out/share/metacubexd/

    runHook postInstall
  '';

  meta = {
    description = "MetaCubeX dashboard for Mihomo";
    homepage = "https://github.com/MetaCubeX/metacubexd";
  };
}
