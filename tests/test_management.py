"""Management integration tests against a private tmux server, never live teams.
Run: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

SCRIPT = Path(__file__).resolve().parents[1] / "tmux-team.sh"


class ManagementTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="team-test-")
        self.root = Path(self.tmp.name)
        self.socket = "team-test-" + uuid.uuid4().hex
        real_tmux = shutil.which("tmux")
        if not real_tmux:
            self.skipTest("tmux not installed")
        self.bin = self.root / ".local/bin"
        self.bin.mkdir(parents=True)
        wrapper = self.bin / "tmux"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(real_tmux) + " -L " + self.socket + " -f /dev/null \"$@\"\n")
        wrapper.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.root), "TMUX_TEAM_CONFIG_DIR": str(self.root / "configs"), "TMUX_TEAM_PREFIX": "team-", "PATH": str(self.bin) + ":" + os.environ["PATH"]}
        self.env.pop("TMUX", None)
        self.env.pop("TMUX_PANE", None)
        (self.root / "configs").mkdir()
        (self.root / "initial").mkdir()
        (self.root / "worker").mkdir()
        self.config = self.root / "configs/demo.json"
        self.config.write_text(json.dumps({"windows": [{"name": "initial", "dir": str(self.root / "initial"), "cmd": ""}]}))
        self.tmux("new-session", "-d", "-s", "team-demo", "-n", "initial", "-c", str(self.root / "initial"), "bash --noprofile --norc")

    def tearDown(self):
        self.tmux("kill-server", check=False)
        self.tmp.cleanup()

    def tmux(self, *args, check=True):
        return subprocess.run([str(self.bin / "tmux"), *args], env=self.env, text=True, capture_output=True, check=check)

    def team(self, *args, check=True):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env, text=True, capture_output=True, check=check, timeout=20)

    def wait_file(self, file):
        for _ in range(50):
            if file.exists():
                return file.read_text()
            time.sleep(.1)
        self.fail(f"command did not produce {file}")

    def test_management(self):
        selected = self.tmux("display-message", "-p", "-t", "team-demo", "#{window_id}").stdout
        output = self.root / "started"
        self.team("join", "demo", str(self.root / "worker"), "--cmd", "printf original > " + shlex.quote(str(output)), "--no-attach")
        self.assertEqual(self.wait_file(output), "original")
        self.assertEqual(selected, self.tmux("display-message", "-p", "-t", "team-demo", "#{window_id}").stdout)
        self.assertNotEqual(self.team("join", "demo", str(self.root / "worker"), "--no-attach", check=False).returncode, 0)
        self.team("set-command", "demo", "worker", "--cmd", "printf changed > " + shlex.quote(str(output)))
        self.assertEqual(output.read_text(), "original", "saving must not restart")
        self.team("restart", "demo", "worker")
        for _ in range(50):
            if output.read_text() == "changed":
                break
            time.sleep(.1)
        self.assertEqual(output.read_text(), "changed")
        pane = self.tmux("display-message", "-p", "-t", "team-demo:worker", "#{pane_id}").stdout.strip()
        self.env["TMUX_PANE"] = pane
        self.assertIn("own window", self.team("restart", "demo", "worker", "--force", check=False).stderr)
        self.env.pop("TMUX_PANE")
        self.tmux("send-keys", "-t", pane, "sleep 60", "Enter")
        time.sleep(.2)
        self.assertIn("running process", self.team("restart", "demo", "worker", check=False).stderr)
        self.team("restart", "demo", "worker", "--force")
        self.team("remove", "demo", "worker")
        self.assertEqual(len(json.loads(self.config.read_text())["windows"]), 1)
        self.assertNotEqual(self.team("remove", "demo", "initial", check=False).returncode, 0)

    def test_literal_and_validation(self):
        self.assertNotEqual(self.team("set-command", "../escape", "initial", "--cmd", "bad", check=False).returncode, 0)
        self.assertNotEqual(self.team("set-command", "demo", "missing", "--cmd", "bad", check=False).returncode, 0)
        self.assertNotEqual(self.team("restart", "demo", "missing", check=False).returncode, 0)
        self.team("set-command", "demo", "initial", "--cmd", "")
        self.assertEqual(json.loads(self.config.read_text())["windows"][0]["cmd"], "")
