#!/usr/bin/env bash
# Install the `team` command and the one service that builds every team when you
# log in. Linux uses a systemd user unit, macOS a launchd agent.
#
#   ./install.sh                 install `team`, start the teams now
#   ./install.sh --no-start      install without starting them
#
# Safe to re-run; each step is idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.adi.team"
BIN_DIR="$HOME/.local/bin"
START=1

for a in "$@"; do
  case "$a" in
    --no-start) START=0 ;;
    *) echo "usage: $(basename "$0") [--no-start]" >&2; exit 1 ;;
  esac
done

command -v tmux >/dev/null || echo "warning: tmux not found (brew install tmux)" >&2

mkdir -p "$BIN_DIR"
ln -sfn "$HERE/tmux-team.sh" "$BIN_DIR/team"
echo "installed $BIN_DIR/team -> $HERE/tmux-team.sh"
# The note has to name the right file: on macOS the login shell is zsh, so
# pointing a Mac user at ~/.bashrc is advice that silently does nothing.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "note: $BIN_DIR is not on your PATH, so 'team' will not resolve by name." >&2
    case "$(basename "${SHELL:-bash}")" in
      zsh)
        echo "  add to ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2 ;;
      fish)
        echo "  run once:  fish_add_path \"\$HOME/.local/bin\"" >&2 ;;
      *)
        echo "  add to ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2 ;;
    esac
    ;;
esac

# Configs used to be pipe-delimited text. Convert any that are still around;
# the original is kept as <name>.conf.bak rather than deleted, since a config is
# not reproducible from anything else once it is gone.
CFG_DIR="${TMUX_TEAM_CONFIG_DIR:-$HERE/configs}"
if compgen -G "$CFG_DIR/*.conf" >/dev/null 2>&1; then
  for old in "$CFG_DIR"/*.conf; do
    new="${old%.conf}.json"
    if [[ -e $new ]]; then
      echo "skip: $(basename "$new") already exists, leaving $(basename "$old") alone"
      continue
    fi
    python3 - "$old" "$new" <<'PYEOF'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
windows = []
for line in open(src):
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    parts = [p.strip() for p in line.split("|")]
    name, dirpath = (parts + ["", ""])[:2]
    cmd = parts[2] if len(parts) > 2 else ""
    if cmd == "-":
        cmd = ""
    if not name or not dirpath:
        print(f"  skip malformed line: {line}", file=sys.stderr)
        continue
    w = {"name": name, "dir": dirpath}
    if cmd:
        w["cmd"] = cmd
    windows.append(w)
with open(dst, "w") as fh:
    json.dump({"windows": windows}, fh, indent=2)
    fh.write("\n")
print(f"  {len(windows)} window(s)")
PYEOF
    mv "$old" "$old.bak"
    echo "migrated $(basename "$old") -> $(basename "$new") (kept $(basename "$old").bak)"
  done
fi

# One service builds every config. A team is a config file, so adding a team is
# writing one and closing a team is deleting it - neither tells the init system
# anything, and a config can never be enabled while missing or missing while
# enabled.
if [[ "$(uname -s)" == "Darwin" ]]; then
  # ------------------------------------------------------------------ launchd --
  # A LaunchAgent runs at *login*, not at boot: macOS has no per-user equivalent
  # of systemd lingering, and there is no user session to own tmux before login.
  mkdir -p "$AGENT_DIR" "$HOME/Library/Logs"
  PLIST="$AGENT_DIR/$LABEL.plist"
  cat > "$PLIST" <<PLISTFILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HERE/tmux-team.sh</string>
    <string>--boot</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TERM</key>
    <string>tmux-256color</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/team.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/team.log</string>
</dict>
</plist>
PLISTFILE
  echo "wrote $PLIST"

  if (( START )); then
    # bootout first so a re-run picks up the new plist; it fails when nothing is
    # loaded, which is fine. bootstrap is the modern spelling of `load -w`, and
    # the fallback covers older systems.
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
    echo "loaded $LABEL -> one session per config in $HERE/configs"
  else
    echo "not loaded; your teams will start at next login"
    echo "  to load it now: launchctl bootstrap gui/$UID $PLIST"
  fi
  echo "logs: ~/Library/Logs/team.log"
else
  # ------------------------------------------------------------------ systemd --
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/tmux-team.service" <<UNITFILE
[Unit]
Description=tmux harness sessions (every team config)
Documentation=file://$HERE/README.md
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
# The tmux server daemonises out of the unit's main process; kill only that
# process on stop so ExecStop can shut the sessions down cleanly instead.
KillMode=process
Environment=TERM=tmux-256color
ExecStart=$HERE/tmux-team.sh --boot
ExecStop=$HERE/tmux-team.sh --stop-all
TimeoutStartSec=300

[Install]
WantedBy=default.target
UNITFILE
  echo "wrote $UNIT_DIR/tmux-team.service"

  # Retire the per-config template and every instance enabled from it.
  if [[ -f $UNIT_DIR/tmux-team@.service ]]; then
    while IFS= read -r inst; do
      [[ -n $inst ]] || continue
      systemctl --user disable "$inst" >/dev/null 2>&1 || true
      echo "retired $inst (left any running session alone)"
    done < <(ls -1 "$UNIT_DIR/default.target.wants" 2>/dev/null | grep '^tmux-team@' || true)
    rm -f "$UNIT_DIR/tmux-team@.service"
    echo "removed the per-config tmux-team@.service template"
  fi

  systemctl --user daemon-reload
  systemctl --user reset-failed 'tmux-team*' >/dev/null 2>&1 || true
  if (( START )); then
    systemctl --user enable --now tmux-team.service
  else
    systemctl --user enable tmux-team.service
  fi
  echo "enabled tmux-team.service -> one session per config in $HERE/configs"

  # Without lingering the user manager is torn down at logout, so nothing starts
  # the sessions until the next interactive login.
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    loginctl enable-linger "$USER" 2>/dev/null \
      && echo "enabled linger for $USER" \
      || echo "note: run 'sudo loginctl enable-linger $USER' for boot (pre-login) start" >&2
  fi
fi

echo
echo "done. 'team --list' to see teams, 'team <name>' to attach."
