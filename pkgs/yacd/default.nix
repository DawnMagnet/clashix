{ stdenvNoCC, fetchzip }:

# yacd-meta: MetaCubeX fork of Yacd
stdenvNoCC.mkDerivation {
  pname = "yacd-meta";
  version = "v0.3.8"; # Or whatever the latest stable is

  # The latest yacd-meta release provides a tarball containing the static files
  src = fetchzip {
    url = "https://codeload.github.com/MetaCubeX/Yacd-meta/zip/refs/heads/gh-pages";
    sha256 = "sha256-6nsAGdD343d/zTTzjccKeAR+6NdJMgaNkfW+QcFJ+s4=";
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
