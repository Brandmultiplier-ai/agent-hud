#!/bin/bash
# Moves Agent HUD onto this Mac after a machine swap.
#
#   bash scripts/move-to-new-mac.sh
#
# Written for the 2026-10 move from the Mac mini M4 to the Mac Studio M5,
# done with Migration Assistant. Migration copies ~/.agent-hud, so the HUD
# arrives with the OLD Mac's web address and keeps announcing it. This puts
# everything right in one pass:
#
#   1. Confirms this Mac's Tailscale name is "agent-hud" (you set it once, in
#      the Tailscale admin page). Naming the address after the HUD rather than
#      the hardware means the NEXT swap needs no plugin rebuild at all.
#   2. Rebuilds the app, opens the HUD's port to the internet, saves the address.
#   3. Changes the private key, and re-points this Mac's Claude Code at it.
#   4. Installs the helper scripts and the login item, then restarts the HUD.
#   5. Builds the new Cowork plugin and copies its hooks file to your clipboard.
#
# Safe to run more than once. It stops at step 1, changing nothing, if the
# name isn't set yet.
#
# RUN THIS IN A NORMAL TERMINAL WINDOW (Cmd-N), not through Claude Code: it
# restarts the HUD and rewrites Claude Code's settings while it runs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUD_DIR="$HOME/.agent-hud"
NAME="agent-hud"
LABEL="com.brandmultiplier.agent-hud"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PLUGIN_ZIP="$HOME/Desktop/agent-hud-live.zip"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '   %s\n' "$1"; }
warn() { printf '\n\033[33m%s\033[0m\n' "$1"; }
fail() { warn "$1"; shift; for l in "$@"; do info "$l"; done; exit 1; }

cfg() { node -e "console.log(require('$ROOT/dist/config.js').loadConfig().$1||'')"; }

say "Moving Agent HUD to this Mac"

command -v node >/dev/null 2>&1 \
  || fail "Node isn't installed, and the HUD needs it." "Install it with:  brew install node" "Then run this again."

# --- 1. the Tailscale name ---------------------------------------------------

say "Step 1 of 5 — checking this Mac's web address"

TS=""
for c in "$(command -v tailscale 2>/dev/null || true)" /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  [ -n "$c" ] && [ -x "$c" ] && { TS="$c"; break; }
done
[ -n "$TS" ] || fail "Tailscale isn't installed on this Mac." \
  "Run:  bash scripts/setup-tailscale.sh   — then run this again."

HOST="$("$TS" status --json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || true)"
[ -n "$HOST" ] || fail "Tailscale is installed but not signed in." \
  "Open the Tailscale app from Applications, sign in, then run this again."

if [ "${HOST%%.*}" != "$NAME" ]; then
  warn "This Mac is still called '${HOST%%.*}' in Tailscale. Nothing has been changed."
  info ""
  info "Rename it to '$NAME' (one time only):"
  info "  1. Open  https://login.tailscale.com/admin/machines"
  info "  2. Find '${HOST%%.*}' in the list. Click the ⋯ at the right of its row."
  info "  3. Choose 'Edit machine name…'."
  info "  4. Switch OFF 'Auto-generate from OS hostname'."
  info "  5. Type  $NAME  and click Update name."
  info ""
  info "If the old Mac mini is still in that list, click its ⋯ and choose 'Remove…'"
  info "first. It's switched off, so removing it costs nothing."
  info ""
  info "Then run this again:  bash scripts/move-to-new-mac.sh"
  exit 0
fi
info "This Mac is $HOST — good."

# --- 2. build, open the port, save the address -------------------------------

say "Step 2 of 5 — rebuilding the app and opening its address"

cd "$ROOT"
if [ ! -x "$ROOT/node_modules/.bin/electron" ]; then
  info "Installing the app's own parts (a minute or two, first time only)…"
  npm install --silent || fail "Couldn't install the app's parts." "Usually the internet. Try again in a minute."
fi
npm run build >/tmp/agent-hud-build.log 2>&1 || {
  tail -20 /tmp/agent-hud-build.log | sed 's/^/   /'
  fail "The rebuild failed. Nothing else was changed." "Send the lines above to Claude Code."
}
info "Built."

PORT="$(cfg port)"
"$TS" funnel --bg "$PORT" >/dev/null 2>&1 || fail "Tailscale wouldn't open the address." \
  "Run:  $TS funnel --bg $PORT" \
  "If it prints a link, open it and click to enable, then run this script again."

HOST="$HOST" node -e "
const c = require('$ROOT/dist/config.js');
const cfg = c.loadConfig();
cfg.tunnelHostname = process.env.HOST;
c.saveConfig(cfg);
"
info "Address saved: https://$HOST"

# --- 3. new key ----------------------------------------------------------------

say "Step 3 of 5 — changing the private key"

node -e "
const c = require('$ROOT/dist/config.js');
const cfg = c.loadConfig();
cfg.ingestSecret = require('node:crypto').randomBytes(32).toString('hex');
c.saveConfig(cfg);
"
chmod 700 "$HUD_DIR" 2>/dev/null || true
info "New key made. The old one stops working when the HUD restarts below."
bash "$ROOT/scripts/install-local-hooks.sh"

# --- 4. helpers, login item, restart -------------------------------------------

say "Step 4 of 5 — installing the login item and restarting the HUD"

mkdir -p "$HUD_DIR" "$HOME/Library/LaunchAgents"
printf '%s\n' "$ROOT" > "$HUD_DIR/project-root"
for f in check.sh launch-hud.sh update.sh; do
  cp "$ROOT/scripts/$f" "$HUD_DIR/$f"
done

# Stop whatever is running, including a copy started by the old login item.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
PIDS="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  # shellcheck disable=SC2086
  kill $PIDS 2>/dev/null || true
  for _ in $(seq 1 20); do
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

sed "s#__HOME__#$HOME#g" "$ROOT/scripts/$LABEL.plist" > "$AGENT_PLIST"
if ! launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1; then
  info "The login item didn't load, so starting the HUD directly this time."
  nohup bash "$HUD_DIR/launch-hud.sh" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

for _ in $(seq 1 30); do
  curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -s -m 5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 \
  || fail "The HUD didn't come back up." "Try:  bash ~/.agent-hud/launch-hud.sh   — and tell Claude Code if that fails too."
info "The HUD is running, and will start by itself when you log in."

# Can the outside world find the address? Asked of Google's public DNS, because
# this Mac resolves its own Tailscale name privately and would always say yes.
PUBLIC=no
for _ in $(seq 1 12); do
  if curl -s -m 5 "https://dns.google/resolve?name=$HOST&type=A" | grep -q '"Status":0'; then
    PUBLIC=yes; break
  fi
  sleep 5
done
if [ "$PUBLIC" = yes ]; then
  info "Confirmed: the internet can find https://$HOST"
else
  warn "The internet can't find https://$HOST yet."
  info "Usually DNS catching up. Carry on with the plugin; if a test thread"
  info "hasn't appeared in 10 minutes, tell Claude Code."
fi

# --- 5. the plugin ---------------------------------------------------------------

say "Step 5 of 5 — building the new Cowork plugin"

bash "$ROOT/scripts/make-plugin.sh" >/dev/null
if command -v pbcopy >/dev/null 2>&1 && unzip -p "$PLUGIN_ZIP" hooks/hooks.json | pbcopy; then
  info "Built, and its hooks file is on your clipboard, ready to paste."
else
  info "Built: $PLUGIN_ZIP"
fi

say "Done on this Mac. One step left, in the Claude app:"
info "  1. Start a new Cowork thread. Type:"
info "       Use create-cowork-plugin to build a plugin named agent-hud-live"
info "       with exactly this hooks/hooks.json:"
info "     then paste (Cmd-V) and send."
info "  2. Click 'Save plugin' on the card it returns."
info "  3. Start another NEW Cowork thread and say hello. A tile should appear."
info ""
info "Do NOT use 'Upload plugin' in the app's settings. It doesn't deliver."
info "If no tile appears, wait overnight before judging. Last time the plugin"
info "took 13 hours to start working."
info ""
info "Claude Code sessions already open on this Mac still have the old key."
info "Close and reopen them and they'll report again."
