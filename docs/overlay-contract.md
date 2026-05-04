# OpenClaw Overlay Contract

`lib.mkGateway` exists to bridge gaps between an OpenClaw release we want to run
and what `openclaw/nix-openclaw`'s scheduled mirror has published. It is a
bypass, not a replacement.

## When to add an overlay

All three must hold:

1. There is a release of `openclaw/openclaw` that we **actually want** — a
   feature or fix we need, not just "newer exists." Newer always exists.
2. `openclaw/nix-openclaw` `main` is at a version less than the one we want.
3. We are not willing to wait for the next mirror cycle.

If only #1 and #2 hold, prefer waiting. The mirror typically catches up within
a day when its CI is healthy.

## How to add an overlay

In the consumer flake (e.g. `loonar-float-nix/flake.nix`):

```nix
services.openclaw.package = openclaw-nix.lib.${system}.mkGateway {
  version = "2026.5.3";
  rev = "229c5d7c…";        # full sha of refs/tags/v2026.5.3 in openclaw/openclaw
  srcHash = "sha256-…";     # hash chase: see below
  pnpmDepsHash = "sha256-…";
  # OVERLAY: drop when openclaw/nix-openclaw mirrors >= 2026.5.3
  # tracking: <issue or PR link>
};
```

The marker comment is **load-bearing**. It lets a future reader (and the
`loonar openclaw drift` watcher) recognise this as an intentional override
with a removal trigger. No marker = no overlay.

### Hash chase

```bash
# 1. Set both hashes to `lib.fakeHash` (or "sha256-AAAA…AAAA").
# 2. Try to build:
nix build .#nixosConfigurations.<host>.config.services.openclaw.package
# 3. The error reports `got: sha256-…` for the mismatched fetch.
# 4. Paste it into the corresponding field, rebuild. Repeat for the second
#    hash (pnpmDepsHash is checked after srcHash succeeds).
```

## When to remove an overlay

Mechanical, not a judgement call:

```
upstream_version = parse(openclaw/nix-openclaw HEAD :
                         nix/sources/openclaw-source.nix → version derived
                         from rev tag)
overlay_version  = parse(consumer flake : mkGateway.version)

if upstream_version >= overlay_version:
    remove overlay, replace with `openclaw.packages.${system}.openclaw-gateway`
```

This is exactly what `loonar openclaw drift --remediate` is intended to
automate. Until it lands, the same diff can be done by hand against
`openclaw/nix-openclaw/main:nix/sources/openclaw-source.nix`.

## Why we don't fork

We deliberately do not fork `openclaw/nix-openclaw`. Forking would make us own
the build seam — `openclaw-gateway-common.nix`, the pnpm/sharp/clipboard
plumbing, the upstream-layout patches that ship there (e.g. the Apr 14 vitest
config path move). That's real work to maintain.

`mkGateway` reuses upstream's seam unchanged and only swaps the source pin.
When upstream patches the seam, we benefit automatically. When upstream stalls
its source mirror, we route around with one small file in the consumer flake.

## What `mkGateway` does not do

- Does not auto-fetch hashes. Hash chase is manual today and will become
  `loonar openclaw upgrade <version>` later.
- Uses this flake's dedicated `nixpkgs-unstable` input (not the `nixpkgs`
  input that consumers may follow-override to a stable channel). The gateway
  derivation has hard requirements on `nodejs_22`, `pnpm_10`,
  `fetchPnpmDeps` — these are unstable-only and overriding the dedicated
  input will break the build. Consumers should leave `nixpkgs-unstable`
  alone.
- Does not provide `openclaw-app` (macOS) or `openclaw-tools`. Linux/x86_64
  only — that's the supported host shape.
