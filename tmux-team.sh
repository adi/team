#!/usr/bin/env bash
# Launch a named harness config as its own tmux session.
#
#   tmux-team.sh                    pick a config, then attach
#   tmux-team.sh <config>           create if needed, then attach
#   tmux-team.sh <config> --detached   create without attaching (systemd / boot)
#   tmux-team.sh <config> --recreate   tear the session down and rebuild it
#   tmux-team.sh --list             list configs and whether they are running
#   tmux-team.sh [config] --colors  print the folder -> colour mapping
#
# Configs live in configs/<name>.conf and each one owns a session called
# "team-<name>", so these never collide with the per-project sessions you keep
# outside this tool. Every tmux command targets the session by *id* ($0, $1, ...)
# because tmux resolves a name target by prefix and pattern.

set -euo pipefail

# Resolve through the ~/.local/bin symlink so configs/ is found next to the real script.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${TMUX_TEAM_CONFIG_DIR:-$HERE/configs}"
SESSION_PREFIX="${TMUX_TEAM_PREFIX-team-}"

# Harnesses live in per-tool bin dirs a non-login systemd unit would not have.
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/bin:$PATH"

# ---------------------------------------------------------------- bar colours --
# 256-colour indices, all light enough to carry black text.
PALETTE=(
  32  33  38  39  40  41  42  43  68  69  70  71  74  75  76  77
  80  81 105 108 110 111 113 114 132 138 140 143 146 149 150 152
 168 173 174 175 178 179 180 181 209 210 211 214 215 216 220 222
)

# barcolor <folder-name> -> "colourNNN"; stable across machines and reboots.
barcolor() {
  local h
  h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf 'colour%s' "${PALETTE[$(( h % ${#PALETTE[@]} ))]}"
}

# ------------------------------------------------------------------- helpers ---
die() { echo "error: $*" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

list_configs() {
  local f
  for f in "$CONFIG_DIR"/*.conf; do
    [[ -e $f ]] || continue
    basename "$f" .conf
  done
}

# Exact-name lookup; prints the session id, or nothing if there is no such session.
session_id() {
  tmux list-sessions -F '#{session_name}	#{session_id}' 2>/dev/null \
    | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'
}

# Emits "name<TAB>dir<TAB>command" per usable window; warns about the rest.
read_config() {
  local line name dir cmd
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    [[ -n ${line//[[:space:]]/} ]] || continue

    IFS='|' read -r name dir cmd <<<"$line"
    name="$(trim "${name:-}")"; dir="$(trim "${dir:-}")"; cmd="$(trim "${cmd:-}")"
    [[ $cmd == '-' ]] && cmd=''
    dir="${dir/#\~/$HOME}"

    if [[ -z $name || -z $dir ]]; then
      echo "skip: malformed line: $line" >&2; continue
    fi

    # A glob in the directory field becomes one window per matching directory,
    # so a config can track a tree instead of freezing today's contents. A name
    # of "*" means "use the folder's own name".
    if [[ $dir == *[*?[]* ]]; then
      local -a matches=(); local m wname had_nullglob
      shopt -q nullglob && had_nullglob=1 || had_nullglob=0
      shopt -s nullglob
      matches=( $dir )
      (( had_nullglob )) || shopt -u nullglob
      if (( ${#matches[@]} == 0 )); then
        echo "skip: '$name' -> nothing matches: $dir" >&2; continue
      fi
      for m in "${matches[@]}"; do
        m="${m%/}"
        [[ -d $m ]] || continue
        wname="$name"
        [[ $wname == '*' ]] && wname="$(basename "$m")"
        printf '%s\t%s\t%s\n' "$wname" "$m" "$cmd"
      done
      continue
    fi

    if [[ ! -d $dir ]]; then
      echo "skip: '$name' -> no such directory: $dir" >&2; continue
    fi
    printf '%s\t%s\t%s\n' "$name" "$dir" "$cmd"
  done <"$CONFIG_FILE"
}

# Poll until the pane has drawn its prompt, max ~3s.
wait_for_prompt() {
  local target="$1" n=0
  while (( n < 60 )); do
    [[ -n $(tmux capture-pane -p -t "$target" | tr -d '[:space:]') ]] && return 0
    sleep 0.05
    (( n++ ))
  done
}

# ------------------------------------------------------------------ session ----
# status-style is a session option and tmux expands #{} inside styles against
# the client's *current* window, so the bar repaints itself from that window's
# @barcolor on every redraw - no hooks, no polling.
style_session() {
  local s="$1"
  tmux set -t "$s" status on \; \
       set -t "$s" status-interval 5 \; \
       set -t "$s" status-justify left \; \
       set -t "$s" status-style "bg=#{?@barcolor,#{@barcolor},colour244},fg=colour232" \; \
       set -t "$s" status-left " #[bold]#S#[nobold] " \; \
       set -t "$s" status-left-length 24 \; \
       set -t "$s" status-right "#[bold]#{b:pane_current_path}#[nobold]  #h  %H:%M " \; \
       set -t "$s" status-right-length 60 \; \
       set -t "$s" base-index 1 \; \
       set -t "$s" renumber-windows on \; \
       set -t "$s" mouse on \; \
       set -t "$s" history-limit 100000 \; \
       set -t "$s" @tmux_setup_config "$CONFIG_NAME"

  # Windows created by hand later must be styled too, or they fall back to the
  # global defaults.
  tmux set-hook -t "$s" after-new-window \
    "run-shell -b '$HERE/tmux-team.sh --style-window \"#{window_id}\"'"
}

# window-status-*, pane-border-* and *-rename are WINDOW options: "set -t <session>"
# would land on that session's current window only. They have to be set per window.
# The current-window highlight itself lives in ~/.tmux.conf as a "setw -g" default
# so every session gets it; only what has to differ per window is here.
style_window() {
  local w="$1" dir
  dir="$(tmux display -p -t "$w" '#{pane_current_path}')"
  tmux set -t "$w" -w @barcolor "$(barcolor "$(basename "$dir")")" \; \
       set -t "$w" -w window-status-activity-style none \; \
       set -t "$w" -w pane-active-border-style "fg=#{?@barcolor,#{@barcolor},colour244}" \; \
       set -t "$w" -w pane-border-style "fg=colour238" \; \
       set -t "$w" -w allow-rename off \; \
       set -t "$w" -w automatic-rename off
}

build_session() {
  local sid='' name dir cmd wid i
  local -a targets=() cmds=()

  while IFS=$'\t' read -r name dir cmd; do
    if [[ -z $sid ]]; then
      sid=$(tmux new-session -d -s "$SESSION" -n "$name" -c "$dir" -P -F '#{session_id}')
      wid=$(tmux display -p -t "$sid" '#{window_id}')
    else
      wid=$(tmux new-window -t "$sid:" -n "$name" -c "$dir" -P -F '#{window_id}')
    fi
    style_window "$wid"
    targets+=("$wid"); cmds+=("$cmd")
  done < <(read_config)

  [[ -n $sid ]] || die "no usable windows in $CONFIG_FILE"

  style_session "$sid"
  tmux move-window -r -t "$sid:"        # renumber from base-index

  # Type the commands only once each shell is ready, otherwise the bare pty
  # echoes the keystrokes before readline exists.
  for i in "${!targets[@]}"; do
    [[ -n ${cmds[i]} ]] || continue
    wait_for_prompt "${targets[i]}"
    tmux send-keys -t "${targets[i]}" "${cmds[i]}" C-m
  done

  tmux select-window -t "${targets[0]}"
  printf '%s\n' "$sid"
}

attach() {
  local sid="$1"
  if [[ -n ${TMUX:-} ]]; then
    tmux switch-client -t "$sid"
  else
    tmux attach-session -t "$sid"
  fi
}

ensure_session() {
  local sid
  sid="$(session_id "$SESSION")"
  [[ -n $sid ]] || sid="$(build_session | tail -1)"
  printf '%s\n' "$sid"
}

show_list() {
  local c sid
  printf '%-16s %-18s %-9s %s\n' CONFIG SESSION STATUS WINDOWS
  for c in $(list_configs); do
    sid="$(session_id "${SESSION_PREFIX}${c}")"
    if [[ -n $sid ]]; then
      printf '%-16s %-18s %-9s %s\n' "$c" "${SESSION_PREFIX}${c}" running \
        "$(tmux list-windows -t "$sid" -F '#{window_name}' | paste -sd, -)"
    else
      printf '%-16s %-18s %-9s %s\n' "$c" "${SESSION_PREFIX}${c}" - \
        "$(CONFIG_FILE="$CONFIG_DIR/$c.conf" read_config 2>/dev/null | cut -f1 | paste -sd, -)"
    fi
  done
}

# Ask which config to load, when none was named on the command line.
pick_config() {
  local -a cfgs=(); local c n reply
  mapfile -t cfgs < <(list_configs)
  (( ${#cfgs[@]} )) || die "no configs in $CONFIG_DIR"
  if (( ${#cfgs[@]} == 1 )); then printf '%s\n' "${cfgs[0]}"; return; fi
  [[ -t 0 && -t 2 ]] || die "no config given; choose one of: ${cfgs[*]}"

  for n in "${!cfgs[@]}"; do
    c="${cfgs[n]}"
    printf '  %d) %-16s %s\n' "$((n+1))" "$c" \
      "$([[ -n $(session_id "${SESSION_PREFIX}${c}") ]] && echo '(running)' || echo '')" >&2
  done
  read -rp "config [1-${#cfgs[@]}]: " reply >&2
  [[ $reply =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#cfgs[@]} )) \
    || die "not a valid choice: $reply"
  printf '%s\n' "${cfgs[reply-1]}"
}

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") [config] [--attach|--detached|--recreate|--colors]
       $(basename "$0") --list
       $(basename "$0") --session <name> <config>

configs in $CONFIG_DIR: $(list_configs | paste -sd' ' -)
USAGE
}

# ---------------------------------------------------------------------- main ---
MODE=attach; CONFIG_NAME=''; SESSION_OVERRIDE=''; STYLE_WID=''
while (( $# )); do
  case "$1" in
    --list)                MODE=list ;;
    --colors|--colours)    MODE=colors ;;
    --recreate)            MODE=recreate ;;
    --detached)            MODE=detached ;;
    --attach)              MODE=attach ;;
    --style-window)        MODE=style-window; STYLE_WID="${2:-}"; shift ;;
    --session)             SESSION_OVERRIDE="${2:-}"; shift ;;
    -h|--help)             usage; exit 0 ;;
    -*)                    usage; die "unknown option: $1" ;;
    *)                     CONFIG_NAME="$1" ;;
  esac
  shift
done

if [[ $MODE == list ]]; then show_list; exit 0; fi
if [[ $MODE == style-window ]]; then
  [[ -n $STYLE_WID ]] || die "--style-window needs a window id"
  style_window "$STYLE_WID"; exit 0
fi

[[ -n $CONFIG_NAME ]] || CONFIG_NAME="$(pick_config)"
CONFIG_FILE="$CONFIG_DIR/$CONFIG_NAME.conf"
[[ -f $CONFIG_FILE ]] || die "no such config: $CONFIG_NAME (have: $(list_configs | paste -sd' ' -))"
SESSION="${SESSION_OVERRIDE:-${SESSION_PREFIX}${CONFIG_NAME}}"

case "$MODE" in
  colors)
    while IFS=$'\t' read -r name dir cmd; do
      printf '%-16s %-34s %s\n' "$name" "$dir" "$(barcolor "$(basename "$dir")")"
    done < <(read_config) ;;
  recreate)
    sid="$(session_id "$SESSION")"
    [[ -n $sid ]] && tmux kill-session -t "$sid"
    attach "$(build_session | tail -1)" ;;
  detached)
    ensure_session >/dev/null ;;
  attach)
    attach "$(ensure_session)" ;;
esac
