# OpenClaw Plugin Architecture Research
## Context: Upgrade Path from v2026.4.x → v2026.5.3

**Date:** 2026-05-05  
**Status:** Investigation into plugin externalization and configuration schema migration  
**Trigger:** Crash-loop on v2026.5.3 upgrade with error `channels.discord: unknown channel id: discord`

---

## Executive Summary

OpenClaw 2026.5.x underwent a **significant plugin externalization wave** where bundled messaging channels (Discord, Codex, and others) were moved from compiled-in extensions to separately-installable npm packages under the `@openclaw/*` scope. This created a critical mismatch:

1. **Nix consumers** (like loonar-float-nix) still write `channels.discord.*` config
2. **v2026.5.x** expects Discord to be pre-installed as `@openclaw/discord` plugin
3. **If not installed**, the gateway fails validation: `unknown channel id: discord`
4. **doctor --fix does NOT auto-install plugins**; it only repairs existing schema and cleans dangling refs

The root cause is a **plugin bootstrap gap**: externalized plugins must be installed before gateway startup, but no automatic migration path exists from v2026.4.x (bundled) → v2026.5.x (external).

---

## 1. Plugin Model: Packaging, Distribution, Loading

### Overview

OpenClaw 2026.5.x uses a **two-tier plugin architecture**:

- **Native plugins**: Implement `openclaw.plugin.json` + runtime module, execute in-process
- **Bundle plugins**: Codex/Claude/Cursor-compatible layouts mapped to OpenClaw features (`.codex-plugin/`, `.claude-plugin/`, etc.)

[Source: Plugin Architecture Docs](https://github.com/openclaw/openclaw/blob/main/docs/tools/plugin.md)

### Plugin Discovery & Loading Order

Plugins load in this precedence (first match wins):

1. `plugins.load.paths` — explicit file/directory paths in config
2. `~/.openclaw/extensions/` — user-installed plugins via `openclaw plugins install <spec>`
3. `.openclaw/` home directory with `.ts` or `index.ts` files
4. Shipped bundled plugins compiled in `dist/extensions`

[Source: Plugin Docs](https://github.com/openclaw/openclaw/blob/main/docs/tools/plugin.md)

### Installation & Package Resolution

**npm-first with ClawHub fallback:**

- `openclaw plugins install <npm-spec>` uses npm pack, extracts to `~/.openclaw/extensions/<id>/`, enables in config
- Scoped packages (`@openclaw/discord`) get normalized: scope + hyphenated prefix → unscoped id
  - Example: `@openclaw/discord` → registered as plugin id `discord`
- Official `@openclaw/*` packages published on npm; external plugins via ClawHub or custom sources

[Source: Plugin Discovery Mechanism](https://github.com/openclaw/openclaw/blob/main/docs/tools/plugin.md)

### Registration API

Each plugin exposes `register(api)` or legacy `activate(api)` during initialization. The `api.registrationMode` indicates context:

- `"full"` — runtime (plugin fully active)
- `"discovery"` — read-only metadata extraction
- `"setup-only"` — installation/onboarding

---

## 2. Externalization Map: Which Features Became Plugins in 2026.5.x

### Confirmed Externalized (Requires Separate Installation)

**High confidence:**

- **Discord** (`@openclaw/discord`) — v2026.5.2+ as external npm package
- **Codex** (`@openclaw/codex`) — OAuth routing, workspace bootstrap support
- **Google Chat** — externalized behind separate npm package
- **WhatsApp** — externalized behind separate npm package
- **Microsoft Teams** — externalized; improved delivery/recovery
- **Slack** — improved delivery/recovery (appears still bundled in 2026.5.3)
- **Diagnostics/OpenTelemetry** (`@openclaw/diagnostics-otel`) — packaged separately

[Source: v2026.5.3 Release Notes](https://github.com/openclaw/openclaw/releases/tag/v2026.5.3) and [v2026.5.2 Release Notes](https://github.com/openclaw/openclaw/releases/tag/v2026.5.2)

### Still Bundled (No Install Needed)

**High confidence:**

- **Telegram** — configured as `channels.telegram`, still built-in; long polling default, webhook optional
- **Matrix** — still bundled; legacy state migration support via doctor
- **Mattermost** — still bundled; streaming support
- **iMessage**, **Twitch**, others — likely still bundled but unconfirmed

[Source: Telegram Channel Docs](https://docs.openclaw.ai/channels/telegram)

### Codex Status: Special Case

Codex is **partially externalized**: exposed in onboarding as a selectable plugin, but with deep integration:

- OAuth routing preserved for `/codex bind` sessions
- Workspace bootstrap files forwarded through native Codex config
- Heartbeat prompts aligned with actual tool availability

[Source: v2026.5.3 Release Notes](https://github.com/openclaw/openclaw/releases/tag/v2026.5.3)

---

## 3. Config Schema Delta: Old Shape → New Shape

### v2026.4.x Configuration (Bundled Channels)

```json
{
  "channels": {
    "discord": {
      "enabled": true,
      "groupPolicy": "allowlist",
      "token": "${DISCORD_BOT_TOKEN}"
    },
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "botToken": "${TELEGRAM_BOT_TOKEN}"
    }
  }
}
```

**Key design**: All channels live under `channels.<id>`, authentication inline or via env reference.

### v2026.5.3 Configuration (Mixed: Bundled + Externalized)

```json
{
  "channels": {
    "discord": {
      "enabled": true,
      "groupPolicy": "allowlist",
      "token": { "source": "env", "provider": "default", "id": "DISCORD_BOT_TOKEN" }
    },
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "botToken": { "source": "env", "provider": "default", "id": "TELEGRAM_BOT_TOKEN" },
      "mediaGroupFlushMs": 300
    }
  },
  "plugins": {
    "enabled": true,
    "bundledDiscovery": "allowlist",
    "entries": {
      "discord": {
        "enabled": true,
        "config": {}
      },
      "codex": {
        "enabled": true,
        "config": {}
      }
    }
  }
}
```

[Source: Configuration Reference](https://docs.openclaw.ai/gateway/configuration-reference) and [Discord Channel Docs](https://docs.openclaw.ai/channels/discord)

### Key Schema Changes

| Aspect | v2026.4.x | v2026.5.x |
|--------|-----------|----------|
| **Token Format** | String or bare env var | SecretRef object: `{ source, provider, id }` |
| **Plugin Config** | N/A (no plugin layer) | `plugins.entries.<id>.config` for installed plugins |
| **Channel Auth** | `channels.<id>.token` or `botToken` | `channels.<id>.token` (SecretRef-capable) |
| **Plugin Discovery** | Hardcoded bundled list | Config-driven + filesystem discovery |
| **Streaming Config** | `channels.<id>.streaming.progress` | Migrated to `streaming.preview.toolProgress` |
| **Multi-Account** | `channels.<id>.accounts.*` | Preserved (still works) |
| **New Hooks** | N/A | `plugins.entries.<id>.hooks.timeoutMs` for timeout tuning |

[Source: Configuration Reference](https://docs.openclaw.ai/gateway/configuration-reference) and [v2026.5.3 Release Notes](https://github.com/openclaw/openclaw/releases/tag/v2026.5.3)

### Channel-Specific Configuration Examples

**Discord (v2026.5.3):**
```json
{
  "channels": {
    "discord": {
      "enabled": true,
      "token": { "source": "env", "provider": "default", "id": "DISCORD_BOT_TOKEN" },
      "groupPolicy": "allowlist",
      "dmPolicy": "pairing",
      "guilds": { "allowlist": ["GUILD_ID"] },
      "replyToMode": "thread",
      "historyLimit": 50,
      "streaming": {
        "preview": { "toolProgress": true }
      }
    }
  }
}
```

**Telegram (still bundled, v2026.5.3):**
```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": { "source": "env", "provider": "default", "id": "TELEGRAM_BOT_TOKEN" },
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "mediaGroupFlushMs": 300
    }
  }
}
```

[Source: Discord Docs](https://docs.openclaw.ai/channels/discord) and [Telegram Docs](https://docs.openclaw.ai/channels/telegram)

---

## 4. The Crash Root Cause & Migration Path

### Why the Error Occurs

When upgrading from v2026.4.x to v2026.5.3:

1. **Existing config contains** `channels.discord.*` (bundled in 2026.4.x)
2. **v2026.5.3 loads** gateway package WITHOUT bundled Discord code
3. **Config validation runs** before plugins load; hardcoded channel list checked
4. **Discord not in hardcoded list** (because plugin not installed) → **validation fails**
5. **Error**: `channels.discord: unknown channel id: discord`
6. **Gateway refuses to start**

[Source: Issue #12484 - "unknown channel id" timing mismatch](https://github.com/openclaw/openclaw/issues/12484)

### What `openclaw doctor --fix` DOES

- Removes stale write-lock files
- Clears legacy plugin dependency staging
- Migrates talk provider restructuring (`talk.*` → `talk.provider` + `talk.providers.<provider>`)
- Removes dangling channel plugin config when plugins are detected as missing
- Cleans up deprecated chrome extension configs
- **DOES NOT** auto-install missing plugins
- **DOES NOT** migrate channels to plugins

[Source: Doctor Command Reference](https://docs.openclaw.ai/gateway/doctor)

### What `openclaw doctor --fix` DOES NOT DO

- **Install plugins automatically** — Discord must be installed via `openclaw plugins install @openclaw/discord` or provided pre-stage into extensions
- **Migrate channel architecture** — `channels.discord` stays under `channels.*`, not moved to `plugins.entries.discord`
- **Repair SecretRef validation issues** — If Discord plugin has SecretRef handling bugs (v2026.5.2 regression), doctor won't fix it

[Source: Doctor Documentation](https://docs.openclaw.ai/gateway/doctor)

---

## 5. Known Issues & Migration Gotchas

### v2026.5.2 SecretRef Regression (Critical)

**Issue**: `@openclaw/discord@2026.5.2` crashes on startup when token is a SecretRef.

**Error**:
```
channels.discord.token: unresolved SecretRef 'env:default:DISCORD_BOT_TOKEN'.
Resolve this command against an active gateway runtime snapshot before reading it.
```

**Root cause**: Externalized Discord plugin uses strict SecretRef resolver during startup, unlike bundled version which handles unresolved refs gracefully.

**Workaround**: Use literal token string (not SecretRef) OR upgrade to patched 2026.5.3+.

[Source: Issue #76371](https://github.com/openclaw/openclaw/issues/76371)

### v2026.4.9 → v2026.4.11 Silent Config Wipe

**Issue**: Updating through v2026.4.9 → 2026.4.10 → 2026.4.11 **silently destroyed** `channels.discord.*` and `agents.list` in openclaw.json.

**Impact**: All backup files (.bak, .bak.1, .bak.2, .bak.3) also missing data — no local recovery path.

**Timeline**: Bug introduced somewhere between 2026.4.9 and 2026.4.11; not documented in changelogs.

[Source: Issue #65105](https://github.com/openclaw/openclaw/issues/65105)

### v2026.4.29 Missing Runtime Dependencies

**Issue**: Bundled Discord and Telegram channels failed to load in packaged installs (missing grammy, discord.js dependencies).

**Status**: Fixed in 2026.5.2+ by externalization; dependencies no longer shipped with core, only with plugin.

[Source: Issue #75685](https://github.com/openclaw/openclaw/issues/75685)

---

## 6. Nix Integration: What Upstream Does

### nix-openclaw Repository Structure

[GitHub: openclaw/nix-openclaw](https://github.com/openclaw/nix-openclaw) provides:

- **`nix/packages/openclaw-gateway.nix`** — Derivation for building gateway from source
- **`nix/packages/openclaw-app.nix`** — macOS app artifact management
- **`nix/modules/home-manager/openclaw/plugin-catalog.nix`** — Built-in plugin catalog
- **`examples/hello-world-plugin/`** — Example plugin flake.nix with `openclawPlugin` output

[Source: nix-openclaw README](https://github.com/openclaw/nix-openclaw)

### Plugin Flake Contract

Example plugin's `flake.nix` must export `openclawPlugin` with:

```nix
{
  openclawPlugin = {
    name = "my-plugin";
    skills = [ ./skill.md ];  # Paths to SKILL.md files
    packages = [ ];           # CLI tools to expose
    needs = {
      directories = [ ];      # Required state dirs
      environment = [ ];      # Required env vars
    };
  };
}
```

[Source: nix-openclaw examples](https://github.com/openclaw/nix-openclaw)

### Current openclaw-nix Module

The local `openclaw-nix` repo's `modules/openclaw-agent.nix`:

- Uses `services.openclaw.settings` to seed `openclaw.json`
- Does **not** manage plugin discovery or installation
- Treats plugins as opaque (whatever the gateway binary ships)
- No `services.openclaw.plugins` option (yet)

[Source: `/mnt/dev/workspaces/openclaw-nix/modules/openclaw-agent.nix`, lines 70–73]

### Build Reuse Pattern

`lib.mkGateway` in `lib/mkGateway.nix` reuses upstream's `nix/packages/openclaw-gateway.nix` + `openclaw-gateway-common.nix` build plumbing when constructing overlay packages with custom OpenClaw source pins. This allows pinning to unreleased commits without duplicating build logic.

[Source: `/mnt/dev/workspaces/openclaw-nix/flake.nix`, line 19-20]

---

## 7. Integration Analysis: Runtime vs Build Time

### Runtime Plugin Loading (npm-based, problematic for Nix)

**How it works:**

1. Gateway starts, reads config
2. Looks for plugins under `~/.openclaw/extensions/`
3. Attempts to load `node_modules` from plugin directories
4. **Problem**: Requires npm packages be present at runtime, not baked into derivation

**For Nix:** This means:

- Plugins cannot be statically composed into the derivation
- Requires either:
  - Pre-staged extensions into state directory before gateway starts
  - Runtime npm install (incompatible with sandboxed/offline builds)
  - Symlinks from Nix store to state directory

[Source: Plugin Loading Docs](https://github.com/openclaw/openclaw/blob/main/docs/tools/plugin.md)

### Plugin Discovery Via Config

Plugins are discovered/enabled via `plugins.entries.<id>` in `openclaw.json`:

```json
{
  "plugins": {
    "entries": {
      "discord": { "enabled": true },
      "codex": { "enabled": true }
    }
  }
}
```

If a plugin is listed but not installed, startup fails validation or plugin initialization errors occur.

[Source: Configuration Reference](https://docs.openclaw.ai/gateway/configuration-reference)

---

## 8. Recommendations for `openclaw-nix` Module Shape

### Option A: Operator-Managed Plugin Install (Current Direction, Minimal)

**Approach:**
- Module provides only `services.openclaw.settings` for channel config
- Plugins are operator responsibility: `openclaw plugins install @openclaw/discord` post-deploy
- Module offers no `services.openclaw.plugins` option

**Pros:**
- Minimal Nix complexity
- Decouples plugin updates from OpenClaw version pins
- Matches upstream design (plugins are runtime-installed, not baked in)

**Cons:**
- Manual step required after deploy/upgrade
- Error-prone if forgotten (crash-loop with "unknown channel id")
- No audit trail in config management

**Recommended for:** Operators who want flexibility and don't mind manual plugin management.

### Option B: Config-Driven Plugin Staging (Recommended)

**Approach:**
- Add `services.openclaw.plugins` NixOS option
- Pre-stage plugin tarballs/links into `~/.openclaw/extensions/<id>/` on activate
- Module writes plugin IDs to `plugins.entries.*` in seed config
- Example:

```nix
services.openclaw = {
  plugins = {
    discord.enable = true;
    discord.package = pkgs.openclaw-discord;  # Custom derivation or npm2nix
    codex.enable = true;
    codex.package = pkgs.openclaw-codex;
  };
};
```

**Pros:**
- Single source of truth in NixOS config
- Reproducible across deploys
- Integrates with secret management (e.g., agenix for plugin auth)
- Can validate plugin presence before gateway starts

**Cons:**
- Requires wrapping upstream npm packages as Nix derivations
- Added complexity if custom plugins used
- Tighter coupling to OpenClaw version

**Recommended for:** Production deployments prioritizing reproducibility.

### Option C: Hybrid (Pragmatic)

**Approach:**
- Add optional `services.openclaw.plugins.preStaged` option (list of plugin packages)
- If empty, no action; if provided, symlink into extensions
- Operators can choose per-deploy: managed via Nix (prod) or manual (dev)

```nix
services.openclaw.plugins.preStaged = [
  pkgs.openclaw-discord
  pkgs.openclaw-codex
];
```

**Pros:**
- Flexibility for both dev and prod workflows
- Backwards compatible (empty list = no change)
- Easier migration path from Option A → Option B

---

## 9. Schema Design for `services.openclaw.plugins`

If implemented, suggested schema:

```nix
services.openclaw.plugins = {
  # Master toggle for plugin system
  enabled = lib.mkEnableOption "externalized plugin system" // { default = true; };

  # Pre-staged packages to symlink into ~/.openclaw/extensions/
  preStaged = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    description = "Plugin packages to pre-stage into ~/.openclaw/extensions/<id>/";
    example = [ pkgs.openclaw-discord ];
  };

  # Per-plugin configuration (complements services.openclaw.settings.plugins.entries)
  entries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable this plugin.";
        };
        config = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Plugin-specific config (merged into openclaw.json).";
        };
      };
    }));
    default = {};
    description = "Per-plugin runtime configuration.";
  };

  # Paths for custom (non-official) plugins
  customPaths = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Additional plugin load paths (passed to plugins.load.paths).";
  };
};
```

---

## 10. Open Questions & Next Steps

### Uncertainties

1. **Telegram externalization status**
   - Currently bundled (confirmed v2026.5.3)
   - Will it be externalized in v2026.6+?
   - **Next**: Monitor release notes; assume bundled for now

2. **Slack, Matrix, Mattermost status**
   - Improved delivery/recovery mentioned, but bundled or external?
   - **Next**: Check if `@openclaw/slack`, `@openclaw/matrix` packages exist on npm

3. **Doctor `--fix` scope in future releases**
   - Will it auto-install plugins in v2026.6+?
   - Will it auto-migrate channel config to plugin shape?
   - **Next**: File tracking issue in openclaw/openclaw if needed

4. **Plugin wrapping for Nix**
   - How to package `@openclaw/discord` as Nix derivation?
   - Reuse `node2nix` or similar? Build from flake.nix?
   - **Next**: Explore `node2nix`, `pnpm2nix`, or ask upstream for Nix package examples

5. **Secret injection into plugins**
   - Can plugins reference agenix secrets like main gateway?
   - Or must they use env vars via `OPENCLAW_*` convention?
   - **Next**: Test with Discord plugin using agenix credentials

### Recommended Immediate Actions

1. **loonar-float-nix**: Understand whether rollback to v2026.4.x is stable, or if v2026.5.3+ is required.
2. **openclaw-nix**: Document that Discord (and other externalized plugins) must be pre-installed; add CI check to validate plugin presence.
3. **Upstream tracking**: Subscribe to [OpenClaw Releases](https://github.com/openclaw/openclaw/releases) and [nix-openclaw](https://github.com/openclaw/nix-openclaw) for plugin roadmap.
4. **Migration script**: Develop helper to auto-install missing plugins post-upgrade (e.g., `openclaw plugins install @openclaw/discord`).

---

## Citations & Sources

- [OpenClaw Plugin Architecture](https://github.com/openclaw/openclaw/blob/main/docs/tools/plugin.md)
- [Configuration Reference](https://docs.openclaw.ai/gateway/configuration-reference)
- [Doctor Command](https://docs.openclaw.ai/gateway/doctor)
- [Discord Channel Docs](https://docs.openclaw.ai/channels/discord)
- [Telegram Channel Docs](https://docs.openclaw.ai/channels/telegram)
- [v2026.5.3 Release Notes](https://github.com/openclaw/openclaw/releases/tag/v2026.5.3)
- [v2026.5.2 Release Notes](https://github.com/openclaw/openclaw/releases/tag/v2026.5.2)
- [Issue #12484 - "unknown channel id" validation timing](https://github.com/openclaw/openclaw/issues/12484)
- [Issue #76371 - @openclaw/discord SecretRef regression](https://github.com/openclaw/openclaw/issues/76371)
- [Issue #65105 - Config wipe on 2026.4.9 → 2026.4.11](https://github.com/openclaw/openclaw/issues/65105)
- [Issue #75685 - v2026.4.29 missing runtime deps](https://github.com/openclaw/openclaw/issues/75685)
- [nix-openclaw Repository](https://github.com/openclaw/nix-openclaw)
- [openclaw-nix local: modules/openclaw-agent.nix](file:///mnt/dev/workspaces/openclaw-nix/modules/openclaw-agent.nix)
- [openclaw-nix local: lib/mkGateway.nix](file:///mnt/dev/workspaces/openclaw-nix/lib/mkGateway.nix)
- [loonar-float-nix: hosts/raft/configuration.nix](file:///mnt/dev/workspaces/loonar-float-nix/hosts/raft/configuration.nix)

