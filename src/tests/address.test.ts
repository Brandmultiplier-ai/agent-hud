// Address check tests. The case that matters is the one that happened: a
// config copied to a new Mac by Migration Assistant, still naming the old one.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { compareAddress, describeAddress } from '../main/address.js';

const SAVED = 'agent-hud.tailbc2fea.ts.net';
const status = (dns: string, backend = 'Running') =>
  JSON.stringify({ BackendState: backend, Self: { DNSName: dns } });

test('same machine: ok, and the footer says nothing extra', () => {
  const c = compareAddress(SAVED, status('agent-hud.tailbc2fea.ts.net.'));
  assert.equal(c.kind, 'ok');
  assert.equal(describeAddress(c), null);
});

test('comparison ignores case and the trailing dot', () => {
  assert.equal(compareAddress('Agent-HUD.tailbc2fea.ts.net.', status('agent-hud.tailbc2fea.ts.net.')).kind, 'ok');
});

test('config from the old Mac: flagged, both names shown, next step given', () => {
  const c = compareAddress('studio-minim4-pro.tailbc2fea.ts.net', status('mac-studio.tailbc2fea.ts.net.'));
  assert.equal(c.kind, 'moved');
  const line = describeAddress(c) ?? '';
  assert.match(line, /studio-minim4-pro/);
  assert.match(line, /mac-studio/);
  assert.match(line, /move-to-new-mac\.sh/);
});

test('Tailscale stopped or signed out: offline', () => {
  assert.equal(compareAddress(SAVED, status('', 'Stopped')).kind, 'offline');
  assert.equal(compareAddress(SAVED, status('', 'NeedsLogin')).kind, 'offline');
});

test('no Tailscale, garbage, or a changed format: unknown, never a false alarm', () => {
  for (const raw of [null, '', 'not json', '{}', JSON.stringify({ Self: {} }), JSON.stringify({ Self: { DNSName: 7 } })]) {
    const c = compareAddress(SAVED, raw);
    assert.equal(c.kind, 'unknown', `input: ${String(raw)}`);
    assert.equal(describeAddress(c), null);
  }
});
