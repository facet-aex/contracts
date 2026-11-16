import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

test('deployment refuses to broadcast without a dedicated private key', () => {
  const env = { ...process.env };
  delete env.FACET_FUJI_DEPLOYER_PRIVATE_KEY;
  const cwd = mkdtempSync(join(tmpdir(), 'facet-deploy-test-'));
  try {
    const run = spawnSync(process.execPath, [resolve('scripts/deploy-facet-contracts-fuji.mjs')], { cwd, env, encoding: 'utf8' });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /FACET_FUJI_DEPLOYER_PRIVATE_KEY/);
  } finally { rmSync(cwd, { recursive: true, force: true }); }
});
