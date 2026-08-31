#!/usr/bin/env bash
# Install the `team` command and the one boot service that builds every team.
#
#   ./install.sh                 install `team`, start the teams now
#   ./install.sh --no-start      install without starting them
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
START=1

for a in "$@"; do
  case "$a" in
    --no-start) START=0 ;;
    *) echo "usage: $(basename "$0") [--no-start]" >&2; exit 1 ;;
  esac
done

mkdir -p "$UNIT_DIR" "$BIN_DIR"
ln -sfn "$HERE/tmux-team.sh" "$BIN_DIR/team"
echo "installed $BIN_DIR/team -> $HERE/tmux-team.sh"

# One unit builds every config. A team is a config file, so adding a team is
# writing one and closing a team is deleting it - neither touches systemd.
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

echo
echo "done. 'team --list' to see teams, 'team <name>' to attach."
