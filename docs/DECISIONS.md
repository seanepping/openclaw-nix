# Decisions

- This repo is a reusable NixOS module library for OpenClaw.
- Fleet/host definitions and agenix secrets live in a separate "fleet" flake.
- Secrets should not be stored in OpenClaw JSON; use systemd credentials + agenix.
- Agent-safe OpenClaw CLI access should use a dedicated wrapper binary with declarative policy, not broad allowlisting of the raw `openclaw` executable.
- OpenClaw native exec approvals are the outer gate; the wrapper policy is the inner gate.
