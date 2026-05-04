{ nixpkgs, nix-openclaw, system }:

# Build openclaw-gateway from a caller-provided source pin, reusing the build
# plumbing in upstream nix-openclaw. Use this when upstream's `main` has not
# yet mirrored a release we need (see docs/overlay-contract.md).
#
# Inputs:
#   version       — informational tag (e.g. "2026.5.3"); shows up in meta
#   rev           — full commit sha in openclaw/openclaw matching `v<version>`
#   srcHash       — sha256 of the fetchFromGitHub source tarball
#   pnpmDepsHash  — sha256 of the resolved pnpm dependency closure
#
# Hash chase: leave srcHash/pnpmDepsHash as `lib.fakeHash`, run `nix build`,
# read the `got: sha256-…` lines from the error, paste them in, repeat until
# the build succeeds.

{ version, rev, srcHash, pnpmDepsHash }:

let
  pkgs = import nixpkgs { inherit system; };
  gateway = pkgs.callPackage (nix-openclaw + "/nix/packages/openclaw-gateway.nix") {
    sourceInfo = {
      owner = "openclaw";
      repo = "openclaw";
      inherit rev;
      hash = srcHash;
      inherit pnpmDepsHash;
    };
  };
in
gateway.overrideAttrs (old: {
  version = version;
  __intentionallyOverridingVersion = true;
  meta = (old.meta or { }) // {
    description = "openclaw-gateway pinned via openclaw-nix.lib.mkGateway (v${version})";
  };
})
