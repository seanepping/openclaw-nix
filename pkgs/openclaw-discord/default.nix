{ lib, fetchurl, buildNpmPackage }:

# OpenClaw Discord plugin — externalized npm package.
#
# The plugin ships pre-compiled in its npm tarball (dist/*.js + openclaw.plugin.json),
# so this derivation only resolves runtime dependencies and stages the plugin tree
# under $out/ for symlinking into /var/lib/openclaw/.openclaw/extensions/discord/.
#
# Output layout matches what the gateway expects when reading
# `~/.openclaw/extensions/<id>/`:
#   $out/openclaw.plugin.json
#   $out/package.json
#   $out/dist/...
#   $out/node_modules/...
#
# Hashes are caller-driven: leave as `lib.fakeHash` and chase via `nix build`.
# See ../../docs/overlay-contract.md for the same pattern used by mkGateway.

let
  version = "2026.5.4";
  npmTarball = fetchurl {
    url = "https://registry.npmjs.org/@openclaw/discord/-/discord-${version}.tgz";
    hash = "sha512-7jPr3XzFjeXZWWkEGKjA8En+wM9+ESupSwyLfSSD0eAqUAb9OhkAsy/eWbJ3+Knt1VDgloZTI71Fq88kFj7ofA==";
  };
in
buildNpmPackage {
  pname = "openclaw-discord";
  inherit version;

  # The npm tarball doesn't ship a package-lock.json (npm pack omits it). We
  # generated one locally by stripping `workspace:*` devDependencies and
  # running `npm install --package-lock-only --omit=dev`, then committed both
  # the lockfile and the cleaned package.json alongside this derivation.
  src = npmTarball;
  postPatch = ''
    cp ${./package.json} package.json
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-ztJUCHb6UuB0rkixMNTIWDbmom2x7hwOcikiCZTrJgs=";

  # Plugin ships pre-built; no compile step.
  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp openclaw.plugin.json $out/
    cp package.json $out/
    cp -r dist $out/
    cp -r node_modules $out/
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenClaw Discord channel plugin (externalized in 2026.5.x)";
    homepage = "https://www.npmjs.com/package/@openclaw/discord";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
