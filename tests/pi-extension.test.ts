import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import extension from "../pi-extension.ts";

test("team tool dispatches exact CLI arguments, never attaches, and guards its own window", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "team-tool-test-"));
  const old = { dir: process.env.PI_TEAM_DIR, config: process.env.TMUX_TEAM_CONFIG_DIR, pane: process.env.TMUX_PANE };
  process.env.PI_TEAM_DIR = root;
  process.env.TMUX_TEAM_CONFIG_DIR = root;
  process.env.TMUX_PANE = "%42";
  fs.writeFileSync(path.join(root, "demo.json"), JSON.stringify({ windows: [{ name: "worker", dir: "/tmp/worker", cmd: "pi --continue" }] }));
  let tool: any;
  const calls: any[] = [];
  extension({
    registerTool: (value: any) => { tool = value; },
    exec: async (command: string, args: string[]) => {
      calls.push([command, args]);
      if (command === "tmux" && args[0] === "display-message") return { code: 0, stdout: "@1\n", stderr: "" };
      if (command === "tmux") return { code: 0, stdout: "team-demo\t@1\tworker\t/tmp/worker\n", stderr: "" };
      return { code: 0, stdout: "done", stderr: "" };
    },
  } as any);
  const run = (params: any) => tool.execute("test", params, new AbortController().signal);
  try {
    assert.match((await run({ action: "list" })).content[0].text, /demo/);
    assert.match((await run({ action: "inspect", team: "demo" })).content[0].text, /pi --continue/);
    await run({ action: "add", team: "demo", dir: "/tmp/a path", command: "pi --continue" });
    assert.deepEqual(calls.at(-1)[1], [path.join(root, "tmux-team.sh"), "join", "demo", "/tmp/a path", "--cmd", "pi --continue", "--no-attach"]);
    await run({ action: "set_command", team: "demo", window: "worker", command: "" });
    assert.equal(calls.at(-1)[1].at(-1), "");
    await assert.rejects(run({ action: "restart", team: "demo", window: "worker", force: true }), /own window/);
    await assert.rejects(run({ action: "remove", team: "demo", window: "worker" }), /own window/);
    await assert.rejects(run({ action: "inspect", team: "../escape" }), /exact team/);
    await assert.rejects(run({ action: "add", team: "demo", dir: "/tmp/project" }), /explicit startup command/);
  } finally {
    for (const [key, value] of Object.entries({ PI_TEAM_DIR: old.dir, TMUX_TEAM_CONFIG_DIR: old.config, TMUX_PANE: old.pane })) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
});
