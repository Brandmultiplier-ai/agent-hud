// Is the web address the HUD advertises actually this Mac's?
//
// The address is saved in config.json when the tunnel is set up. Migration
// Assistant copies that file to a new Mac, and the HUD then went on announcing
// "Listening … on studio-minim4-pro…" for a machine that no longer existed.
// Nothing checked. This does: it asks Tailscale for this Mac's own name and
// compares.
//
// Only Tailscale's `status --json` is read, and only `Self.DNSName` from it —
// the same field scripts/setup-tailscale.sh has relied on since Phase 1. If
// the command is missing, slow, or changes shape, the answer is "couldn't
// check", never a false alarm and never a crash.

import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';

/** Where Tailscale's command lives on a Mac, in the order worth trying. */
const TAILSCALE_PATHS = [
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/opt/homebrew/bin/tailscale',
  '/usr/local/bin/tailscale',
];

export type AddressCheck =
  /** Saved address is this Mac's. */
  | { kind: 'ok' }
  /** Saved address belongs to some other machine — a swap or a rename. */
  | { kind: 'moved'; saved: string; actual: string }
  /** Tailscale is installed but not connected, so nothing can reach the HUD. */
  | { kind: 'offline' }
  /** Couldn't ask. Says nothing either way. */
  | { kind: 'unknown' };

/** Pure comparison, separated so it can be tested without Tailscale. */
export function compareAddress(saved: string, statusJson: string | null): AddressCheck {
  if (statusJson === null) return { kind: 'unknown' };
  let parsed: unknown;
  try {
    parsed = JSON.parse(statusJson);
  } catch {
    return { kind: 'unknown' };
  }
  const p = parsed as { BackendState?: unknown; Self?: { DNSName?: unknown } };
  if (p.BackendState === 'Stopped' || p.BackendState === 'NeedsLogin') return { kind: 'offline' };
  const name = typeof p.Self?.DNSName === 'string' ? p.Self.DNSName : '';
  const actual = name.replace(/\.$/, '').toLowerCase();
  if (!actual) return { kind: 'unknown' };
  return actual === saved.replace(/\.$/, '').toLowerCase()
    ? { kind: 'ok' }
    : { kind: 'moved', saved, actual };
}

function tailscaleStatus(): Promise<string | null> {
  const bin = TAILSCALE_PATHS.find((p) => existsSync(p));
  if (!bin) return Promise.resolve(null);
  return new Promise((resolve) => {
    execFile(bin, ['status', '--json'], { timeout: 5000 }, (_err, stdout) => {
      // `status` exits non-zero when stopped but still prints the JSON.
      resolve(stdout ? stdout : null);
    });
  });
}

export async function checkAddress(saved: string): Promise<AddressCheck> {
  return compareAddress(saved, await tailscaleStatus());
}

/** The first part of a hostname — enough to recognise, short enough to read. */
function short(host: string): string {
  return host.split('.')[0] ?? host;
}

/** Plain-language status for the HUD's footer, or null when there is nothing to say. */
export function describeAddress(check: AddressCheck): string | null {
  switch (check.kind) {
    case 'moved':
      return `This Mac's web address has changed (saved: ${short(check.saved)}, this Mac: ${short(check.actual)}), so cloud threads can't reach the HUD · run: bash scripts/move-to-new-mac.sh`;
    case 'offline':
      return "Tailscale isn't connected, so cloud threads can't reach the HUD · open the Tailscale app and sign in";
    default:
      return null;
  }
}
