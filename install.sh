#!/usr/bin/env bash
# Install the `team` command and a boot-time user service per config.
#
#   ./install.sh                 install `team`, enable every config at boot
#   ./install.sh example         install `team`, enable only these configs
#   ./install.sh --no-start ...  enable at boot without starting now
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
TMUX_BIN="$(command -v tmux)"
PREFIX="${TMUX_TEAM_PREFIX-team-}"
START=1

args=()
for a in "$@"; do
  case "$a" in
    --no-start) START=0 ;;
    *) args+=("$a") ;;
  esac
done
if (( ${#args[@]} == 0 )); then
  mapfile -t args < <(cd "$HERE/configs" && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//')
fi
(( ${#args[@]} )) || { echo "no configs found in $HERE/configs" >&2; exit 1; }

mkdir -p "$UNIT_DIR" "$BIN_DIR"
ln -sfn "$HERE/tmux-team.sh" "$BIN_DIR/team"
echo "installed $BIN_DIR/team -> $HERE/tmux-team.sh"

# One templated unit serves every config: tmux-team@<config>.service
cat > "$UNIT_DIR/tmux-team@.service" <<UNITFILE
[Unit]
Description=tmux harness session (%i)
Documentation=file://$HERE/README.md
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
# The tmux server daemonises out of the unit's main process; kill only that
# process on stop so ExecStop can shut the session down cleanly instead.
KillMode=process
Environment=TERM=tmux-256color
ExecStart=$HERE/tmux-team.sh %i --detached
ExecStop=$TMUX_BIN kill-session -t =$PREFIX%i
TimeoutStartSec=120

[Install]
WantedBy=default.target
UNITFILE
echo "wrote $UNIT_DIR/tmux-team@.service"

# Retire the pre-config single-session unit if it is still around.
if [[ -f $UNIT_DIR/tmux-team.service ]]; then
  systemctl --user disable tmux-team.service >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/tmux-team.service"
  echo "retired the old tmux-team.service (left any running session alone)"
fi

systemctl --user daemon-reload
for c in "${args[@]}"; do
  [[ -f $HERE/configs/$c.conf ]] || { echo "skip: no such config: $c" >&2; continue; }
  if (( START )); then
    systemctl --user enable --now "tmux-team@$c.service"
  else
    systemctl --user enable "tmux-team@$c.service"
  fi
  echo "enabled tmux-team@$c -> session ${PREFIX}${c}"
done

# Without lingering the user manager is torn down at logout, so nothing starts
# the sessions until the next interactive login.
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
  loginctl enable-linger "$USER" 2>/dev/null \
    && echo "enabled linger for $USER" \
    || echo "note: run 'sudo loginctl enable-linger $USER' for boot (pre-login) start" >&2
fi

echo
echo "done. 'team --list' to see configs, 'team <config>' to attach."
