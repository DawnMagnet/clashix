{ stdenvNoCC, fetchzip }:

# metacubexd: Official dashboard from MetaCubeX
stdenvNoCC.mkDerivation rec {
  pname = "metacubexd";
  version = "v1.247.0";

  src = fetchzip {
    url = "https://github.com/MetaCubeX/metacubexd/releases/download/${version}/compressed-dist.tgz";
    sha256 = "sha256-VinNCJkO1mpkuQFk5/5oLJKRXGBeWozIf+MQYhQxuOM=";
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
