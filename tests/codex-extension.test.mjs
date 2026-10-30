import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { Adapter } from '../codex-extension.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(repo, 'codex-extension.mjs');
const sid = '12345678-1234-1234-1234-123456789abc';
const sid2 = '12345678-1234-1234-1234-123456789abd';
test('team exact CLI dispatch preserves literal commands and blocks self mutation', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-team-test-'));
  fs.writeFileSync(path.join(root, 'demo.json'), JSON.stringify({ windows: [{ name: 'worker', dir: '/tmp/worker', cmd: 'pi --continue' }] }));
  const calls = [];
  const adapter = new Adapter({ ...process.env, CODEX_TEAM_DIR: root, TMUX_TEAM_CONFIG_DIR: root }, async (command, args) => {
    calls.push([command, args]);
    if (command === 'tmux' && args[0] === 'display-message') return { stdout: '@1\n', stderr: '' };
    if (command === 'tmux') return { stdout: 'team-demo\t@1\tworker\t/tmp/worker\n', stderr: '' };
    return { stdout: 'done', stderr: '' };
  });
  try {
    assert.match((await adapter.team({ action: 'list' })).content[0].text, /demo/);
    assert.match((await adapter.team({ action: 'inspect', team: 'team-demo' })).content[0].text, /pi --continue/);
    await adapter.team({ action: 'add', team: 'demo', dir: '/tmp/a path', command: 'codex resume --last' });
    assert.deepEqual(calls.at(-1), ['bash', [path.join(root, 'tmux-team.sh'), 'join', 'demo', '/tmp/a path', '--cmd', 'codex resume --last', '--no-attach']]);
    await adapter.team({ action: 'set_command', team: 'demo', window: 'worker', command: '' });
    assert.equal(calls.at(-1)[1].at(-1), '');
    await assert.rejects(adapter.team({ action: 'restart', team: 'demo', window: 'worker' }), /caller_pane/);
    for (const action of ['restart', 'remove']) await assert.rejects(adapter.team({ action, team: 'demo', window: 'worker', caller_pane: '%42', force: true }), /own window/);
    await assert.rejects(adapter.team({ action: 'inspect', team: '../escape' }), /exact team/);
    await assert.rejects(adapter.team({ action: 'add', team: 'demo', dir: '/tmp/project' }), /explicit authorized/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('MCP transport discovers only team management and returns structured errors', () => {
  const input = [
    '{broken',
    JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } } }),
    JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }),
    JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'team_manage', arguments: { action: 'inspect', team: '../escape' } } }),
    JSON.stringify({ jsonrpc: '2.0', id: 4, method: 'nonexistent' }),
  ].join('\n') + '\n';
  const child = spawnSync(process.execPath, [script, '--mcp'], { input, encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr);
  const messages = child.stdout.trim().split('\n').map(JSON.parse);
  assert.equal(messages[0].error.code, -32700);
  assert.equal(messages[1].result.protocolVersion, '2025-06-18');
  assert.deepEqual(messages[2].result.tools.map(t => t.name), ['team_manage']);
  assert.equal(messages[3].result.isError, true);
  assert.equal(messages[4].error.code, -32601);
});
