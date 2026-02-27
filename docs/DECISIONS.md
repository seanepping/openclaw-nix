# Decisions

- This repo is a reusable NixOS module library for OpenClaw.
- Fleet/host definitions and agenix secrets live in a separate "fleet" flake.
- Secrets should not be stored in OpenClaw JSON; use systemd credentials + agenix.
