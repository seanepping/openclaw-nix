# openclaw.nix

Reusable NixOS module(s) for running OpenClaw with deployment-managed configuration and credentials.

Current state:
- OpenClaw service module for gateway/agent deployments
- systemd credential-based secret injection
- reusable agent CLI wrapper module for narrow, policy-enforced CLI access

Documentation:
- `docs/usage.md`
- `docs/decisions.md`
- `docs/agent-cli-wrapper-design.md`
