{
  lib,
  stdenv,
  nodejs,
  fetchurl,
  buildNpmPackage,
  makeWrapper,
  ripgrep,
  fd,
}:

let
  version = "2.3.3";
in
buildNpmPackage {
  pname = "kimi-code";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@moonshot-ai/kimi-code/-/kimi-code-${version}.tgz";
    hash = "sha256-P6D27o8DmMmvTLb9SFms86zoR6k4d8kwcxcus1D9LQI=";
  };

  # The npm tarball ships a pre-built dist/main.mjs bundle (497k lines, all
  # devDependencies inlined). Only three runtime npm deps remain external:
  # ws, chokidar, qrcode.
  #
  # The published package.json carries devDependencies with workspace:^
  # references (e.g. @moonshot-ai/acp-server) that npm cannot resolve.
  # We strip everything except the three runtime deps and supply a
  # matching package-lock.json.
  npmDepsHash = "sha256-cWuMNalIpL9hRUmK7ZbwYXWcc9QCN9j3aTlcJ0wUpCk=";

  postPatch = ''
    # Replace package.json with one that only has the three runtime deps
    # so npm does not try to resolve workspace: devDependencies.
    cat > package.json <<'EOF'
    {
      "name": "@moonshot-ai/kimi-code",
      "version": "${version}",
      "bin": { "kimi": "dist/main.mjs" },
      "dependencies": {
        "chokidar": "^4.0.3",
        "qrcode": "^1.5.4",
        "ws": "^8.18.0"
      }
    }
    EOF
    cp ${./package-lock.json} ./package-lock.json
  '';

  # No npm build step; the dist/ is already built in the tarball.
  dontNpmBuild = true;

  # Skip postinstall: it only renames legacy Python kimi shims on global npm
  # installs. Under Nix it is a no-op.
  npmFlags = [ "--ignore-scripts" ];

  inherit nodejs;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/kimi \
      --prefix PATH : ${lib.makeBinPath [ ripgrep fd ]} \
      --set KIMI_CODE_NO_AUTO_UPDATE 1
  '';

  meta = {
    description = "Kimi Code CLI - The Starting Point for Next-Gen Agents";
    homepage = "https://github.com/MoonshotAI/kimi-code";
    license = lib.licenses.mit;
    mainProgram = "kimi";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
