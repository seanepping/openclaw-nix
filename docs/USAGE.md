# Usage (Hybrid Layout)

This repo provides a NixOS module.

Recommended layout:
- `openclaw-nix` (this repo): reusable module(s)
- `fleet` repo: your machine configs + agenix secrets + deploy method

## In your fleet flake

Add inputs:

```nix
inputs.openclaw-nix.url = "path:/path/to/openclaw-nix";
inputs.openclaw-nix.inputs.nixpkgs.follows = "nixpkgs";
```

Then in a host module list:

```nix
modules = [
  agenix.nixosModules.default
  openclaw-nix.nixosModules.default
  ./hosts/emacagent/configuration.nix
];
```

## Secrets

Use agenix to render secret files under `/run/agenix/...` (root-owned).
Pass them to OpenClaw via `services.openclaw.credentials`.
