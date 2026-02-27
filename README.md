# openclaw.nix

NixOS configuration for running OpenClaw (gateway/agent) + secrets management.

Goals:
- Own the module/config (avoid depending on stale external nix-openclaw)
- Use agenix for secrets stored in git
- Keep `/var/lib/openclaw/openclaw.json` non-secret where possible
- Inject secrets via systemd credentials/env, not plaintext config

Status: scaffold
