{ stdenv, fetchzip }:

# yacd-meta: MetaCubeX fork of Yacd
stdenv.mkDerivation {
  pname = "yacd-meta";
  version = "v0.3.8"; # Or whatever the latest stable is

  # The latest yacd-meta release provides a tarball containing the static files
  src = fetchzip {
    url = "https://codeload.github.com/MetaCubeX/Yacd-meta/zip/refs/heads/gh-pages";
    sha256 = "0gnhipsb76k5ha8i6rj9d5nhr9psy94njyi500fvbbd6j20y1qkj";
    extension = "zip";
    stripRoot = false;
  };

  # No build phase needed for pre-compiled static files
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/yacd
    cp -r $src/* $out/share/yacd/

    runHook postInstall
  '';

  meta = {
    description = "Yet Another Clash Dashboard (MetaCubeX fork)";
    homepage = "https://github.com/MetaCubeX/Yacd-meta";
  };
}
