#!/bin/bash
# Points Claude Code sessions on this Mac at the HUD, with the current key.
#
#   bash scripts/install-local-hooks.sh
#
# Run by setup.sh, and again by move-to-new-mac.sh after the key changes.
# Your other Claude Code settings are kept: the file is merged, never
# overwritten, and a timestamped backup is taken first.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

info() { printf '   %s\n' "$1"; }

PORT=$(node -e "console.log(require('$ROOT/dist/config.js').loadConfig().port)")
SECRET=$(node -e "console.log(require('$ROOT/dist/config.js').loadConfig().ingestSecret)")

mkdir -p "$HOME/.claude"
if [ -f "$CLAUDE_SETTINGS" ]; then
  BACKUP="$CLAUDE_SETTINGS.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$CLAUDE_SETTINGS" "$BACKUP"
  info "Backed up your existing settings to:"
  info "  $BACKUP"
else
  echo '{}' > "$CLAUDE_SETTINGS"
fi

HUD_PORT="$PORT" HUD_SECRET="$SECRET" python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
port   = os.environ["HUD_PORT"]
secret = os.environ["HUD_SECRET"]
url    = f"http://127.0.0.1:{port}/ingest/local"

# The 14 lifecycle events the HUD consumes. Each one was captured live during
# Phase 0 except StopFailure and SessionStart — those are included defensively
# and cost nothing if they never fire.
EVENTS = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "Notification",
    "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop",
    "Stop", "StopFailure", "SessionEnd",
]
MATCHED = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"}

try:
    with open(path) as f:
        settings = json.load(f)
except Exception:
    settings = {}

hooks = settings.setdefault("hooks", {})

def is_ours(entry):
    for h in entry.get("hooks", []):
        if h.get("type") == "http" and "/ingest/local" in str(h.get("url", "")):
            return True
    return False

added = 0
for event in EVENTS:
    entries = [e for e in hooks.get(event, []) if not is_ours(e)]  # replace ours, keep theirs
    # A 3-second timeout means that if the HUD is closed, your Claude sessions
    # pause for at most 3 seconds per event and then carry on normally.
    # The secret goes in the file so you never handle it. Every write to the
    # HUD is authenticated, including this one - see src/ingest/server.ts.
    handler = {"type": "http", "url": url, "timeout": 3,
               "headers": {"X-Hud-Secret": secret}}
    entry = {"hooks": [handler]}
    if event in MATCHED:
        entry["matcher"] = "*"
    entries.append(entry)
    hooks[event] = entries
    added += 1

with open(path, "w") as f:
    json.dump(settings, f, indent=2)

print(f"   Registered {added} events. Your other settings were left alone.")
PY
