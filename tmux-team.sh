#!/usr/bin/env bash
# Launch a named harness config as its own tmux session.
#
#   tmux-team.sh                    pick a config, then attach
#   tmux-team.sh <config>           create if needed, then attach
#   tmux-team.sh new [dir]          start a team of one from a folder
#   tmux-team.sh join <team> [dir]  add a folder to an existing team
#   tmux-team.sh close <team>       shut a team down, keeping sessions resumable
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

# Names of running teams that have no config file behind them.
list_adhoc() {
  local name
  while IFS= read -r name; do
    [[ $name == "$SESSION_PREFIX"* ]] || continue
    name="${name#$SESSION_PREFIX}"
    [[ -f "$CONFIG_DIR/$name.conf" ]] || printf '%s\n' "$name"
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# Exact-name lookup; prints the session id, or nothing if there is no such session.
# Note the `|| true`: with no tmux server running at all, list-sessions exits 1,
# and under `set -o pipefail` that aborted the entire script - precisely on the
# first run after boot, when there is no server yet and a session has to be
# built. Every tmux query that can legitimately find nothing needs this.
session_id() {
  { tmux list-sessions -F '#{session_name}	#{session_id}' 2>/dev/null \
    | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'; } || true
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

# has_claude_session <dir>: true if Claude Code has a resumable *interactive*
# session for <dir> - a *.jsonl transcript under ~/.claude/projects/<munged
# path>, where every non-alphanumeric path character becomes '-'.
#
# File presence alone is not enough: a folder can hold transcripts from one-shot
# -p/SDK runs ("entrypoint":"sdk-cli") which `--continue` refuses to resume
# ("No conversation found to continue"), so require one real interactive
# transcript. Getting this wrong hands the user a dead window.
has_claude_session() {
  local slug=${1//[^a-zA-Z0-9]/-} f
  for f in "$HOME/.claude/projects/$slug"/*.jsonl; do
    [[ -e $f ]] || continue
    grep -q '"entrypoint":"cli"' "$f" && return 0
  done
  return 1
}

# claude_cmd <dir> -> the command to type in a window for <dir>.
claude_cmd() {
  if has_claude_session "$1"; then printf 'claude --continue'; else printf 'claude'; fi
}

# Add one window for <dir> to session <sid> and start its harness in it.
add_window() {
  local sid="$1" dir="$2" wid
  wid=$(tmux new-window -t "$sid:" -n "$(basename "$dir")" -c "$dir" -P -F '#{window_id}')
  style_window "$wid"
  wait_for_prompt "$wid"
  tmux send-keys -t "$wid" "$(claude_cmd "$dir")" C-m
  printf '%s\n' "$wid"
}

# Poll until the pane has drawn its prompt, max ~3s.
#
# n is incremented with an assignment, not (( n++ )): that form evaluates to the
# OLD value, so on the first pass it returns 0 -> exit status 1, and under
# `set -e` the whole script dies right there. It only triggers when the pane is
# still blank on the first look, which is exactly the case this loop exists for.
wait_for_prompt() {
  local target="$1" n=0
  while (( n < 60 )); do
    [[ -n $(tmux capture-pane -p -t "$target" | tr -d '[:space:]') ]] && return 0
    sleep 0.05
    n=$(( n + 1 ))
  done
  return 0   # a slow pane is not fatal; type into it anyway
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
  local c sid s
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

  # A running team whose config is gone (deleted, or built with --session) would
  # otherwise be invisible here. `team save <name>` gives it one back.
  while IFS=$'\t' read -r s sid; do
    [[ $s == "$SESSION_PREFIX"* ]] || continue
    c="${s#$SESSION_PREFIX}"
    [[ -f "$CONFIG_DIR/$c.conf" ]] && continue
    printf '%-16s %-18s %-9s %s\n' "(unsaved)" "$s" running \
      "$(tmux list-windows -t "$sid" -F '#{window_name}' | paste -sd, -)"
  done < <(tmux list-sessions -F '#{session_name}	#{session_id}' 2>/dev/null)
}

# Ask which config to load, when none was named on the command line.
pick_config() {
  local -a cfgs=(); local c n reply
  mapfile -t cfgs < <(list_configs; list_adhoc)
  (( ${#cfgs[@]} )) || die "no configs in $CONFIG_DIR and no teams running"
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

# team new [dir] [--name <team>] [--detached]: start a team from one folder.
#
# This writes configs/<name>.conf and then builds it through the same path as any
# other team. Teams used to exist as tmux state alone, which made them a second
# class the rest of the tool had to special-case; a team is a config, full stop.
cmd_new() {
  local dir='' name='' detached=0
  while (( $# )); do
    case "$1" in
      --name)      name="${2:-}"; shift ;;
      --detached)  detached=1 ;;
      -h|--help)   echo "usage: $(basename "$0") new [dir] [--name <team>] [--detached]" >&2; exit 0 ;;
      -*)          die "unknown option: $1" ;;
      *)           dir="$1" ;;
    esac
    shift
  done

  dir="$(cd "${dir:-$PWD}" 2>/dev/null && pwd)" || die "no such directory: ${dir:-$PWD}"
  name="${name:-$(basename "$dir")}"
  CONFIG_NAME="$name"
  CONFIG_FILE="$CONFIG_DIR/$name.conf"
  SESSION="${SESSION_PREFIX}${name}"

  [[ -z $(session_id "$SESSION") ]] \
    || die "$SESSION is already running - 'team join $name $dir' to add this folder, or 'team $name' to attach"
  [[ ! -f $CONFIG_FILE ]] \
    || die "config '$name' already exists - 'team $name' to start it, or pass --name for a different team"

  { config_header "$name" new; config_line "$dir"; } >"$CONFIG_FILE"
  echo "wrote $CONFIG_FILE" >&2

  if (( detached )); then
    ensure_session >/dev/null
  else
    attach "$(ensure_session)"
  fi
}

# team join <team> [dir] [--detached]: add a folder to a team.
#
# The folder is appended to the team's config, so it is part of the team the next
# time it is built, and added as a live window when the team is running now.
cmd_join() {
  local team='' dir='' detached=0
  while (( $# )); do
    case "$1" in
      --detached)  detached=1 ;;
      -h|--help)   echo "usage: $(basename "$0") join <team> [dir] [--detached]" >&2; exit 0 ;;
      -*)          die "unknown option: $1" ;;
      *)           if [[ -z $team ]]; then team="$1"; else dir="$1"; fi ;;
    esac
    shift
  done

  [[ -n $team ]] || die "usage: $(basename "$0") join <team> [dir]"
  dir="$(cd "${dir:-$PWD}" 2>/dev/null && pwd)" || die "no such directory: ${dir:-$PWD}"

  local name="${team#$SESSION_PREFIX}"
  CONFIG_NAME="$name"
  CONFIG_FILE="$CONFIG_DIR/$name.conf"
  SESSION="${SESSION_PREFIX}${name}"
  local sid; sid="$(session_id "$SESSION")"

  # A session with no config predates this behaviour; capture what it is running
  # before appending, so nothing already in the team is lost.
  if [[ ! -f $CONFIG_FILE ]]; then
    [[ -n $sid ]] || die "no team called '$name' - 'team new $dir --name $name' to start one"
    echo "saved the running lineup to $(save_team "$sid" "$name")" >&2
  fi

  # Two windows on one folder would both --continue the same transcript.
  grep -Fxq "$dir" <(config_dirs "$CONFIG_FILE") \
    && die "$dir is already in team '$name'"
  config_line "$dir" >>"$CONFIG_FILE"
  echo "added $(basename "$dir") to $CONFIG_FILE" >&2

  if [[ -z $sid ]]; then
    echo "team '$name' is not running - 'team $name' to start it" >&2
    return 0
  fi

  local wid; wid="$(add_window "$sid" "$dir")"
  tmux select-window -t "$wid"
  (( detached )) || attach "$sid"
}

# Panes running something other than a login shell - i.e. a live harness.
busy_panes() {
  { tmux list-panes -s -t "$1" -F '#{pane_id} #{pane_current_command}' 2>/dev/null \
    | awk '$2 != "bash" && $2 != "zsh" && $2 != "sh" && $2 != "fish" && $2 != "dash" { print $1 }'; } || true
}

# One line of a config file: "name | dir | command", ~ kept short.
config_line() {
  local dir="$1"
  printf '%-14s | %-34s | %s\n' "$(basename "$dir")" "${dir/#$HOME/\~}" "$(claude_cmd "$dir")"
}

config_header() {
  printf '# %s: written by `team %s` on %s.\n' "$1" "$2" "$(date +%Y-%m-%d)"
  printf '#   name | directory | command\n\n'
}

# Directories a config already lists, one per line.
config_dirs() {
  [[ -f $1 ]] || return 0
  CONFIG_FILE="$1" read_config 2>/dev/null | cut -f2
}

# Write a config file from a team's live windows, so a team that has no config
# yet survives being closed. The harness command is decided per folder the same way `new`
# does it, rather than frozen as --continue: a folder whose transcript is not
# resumable would otherwise reopen straight onto "No conversation found".
save_team() {
  local sid="$1" name="$2" dest="$CONFIG_DIR/$name.conf" dir
  {
    printf '# %s: saved from the running team on %s.\n' "$name" "$(date +%Y-%m-%d)"
    printf '#   name | directory | command\n\n'
    while IFS=$'\t' read -r wname dir; do
      printf '%-14s | %-34s | %s\n' "$wname" "${dir/#$HOME/\~}" "$(claude_cmd "$dir")"
    done < <(tmux list-windows -t "$sid" -F '#{window_name}	#{pane_current_path}')
  } >"$dest"
  printf '%s\n' "$dest"
}

# team save [team]: write a config from a running team without closing it.
cmd_save() {
  local team="${1:-}"
  [[ -n $team || -z ${TMUX:-} ]] || team="$(tmux display -p '#{session_name}')"
  [[ -n $team ]] || die "usage: $(basename "$0") save <team>"
  local name="${team#$SESSION_PREFIX}" sid
  sid="$(session_id "${SESSION_PREFIX}${name}")"
  [[ -n $sid ]] || die "no running team called '$name'"
  echo "wrote $(save_team "$sid" "$name")" >&2
}

# team close <team> [--no-save] [--force]: shut a team down, leaving every Claude
# session resumable.
#
# Claude writes its transcript as it goes, so a killed pane is usually still
# resumable - but "usually" is not good enough for the thing the user cares most
# about keeping, so ask each harness to exit and only then take the session down.
cmd_close() {
  local team='' nosave=0 force=0
  while (( $# )); do
    case "$1" in
      --no-save)  nosave=1 ;;
      --force)    force=1 ;;
      -h|--help)  echo "usage: $(basename "$0") close <team> [--no-save] [--force]" >&2; exit 0 ;;
      -*)         die "unknown option: $1" ;;
      *)          team="$1" ;;
    esac
    shift
  done

  # Deliberately no implicit target: closing a team is not the kind of thing to
  # infer from where the shell happens to be sitting.
  [[ -n $team ]] || die "usage: $(basename "$0") close <team>"

  local session="$team" sid
  [[ $session == "$SESSION_PREFIX"* ]] || session="${SESSION_PREFIX}${team}"
  sid="$(session_id "$session")"
  [[ -n $sid ]] || die "no running team called '$team'"
  local name="${session#$SESSION_PREFIX}"

  # Teams written by `new`/`join` already have a config; this catches a session
  # that predates that, or one made with --session.
  if (( ! nosave )) && [[ ! -f "$CONFIG_DIR/$name.conf" ]]; then
    echo "saved lineup to $(save_team "$sid" "$name")" >&2
  fi
  echo "'team $name' will rebuild it, resuming each folder's session" >&2

  if (( ! force )); then
    local pane n=0 asked=0
    # Anything that is not a bare shell is treated as a harness worth asking.
    # Matching on the command being exactly "claude" would miss it the moment it
    # runs behind a wrapper, and the cost of asking a non-harness is one
    # "command not found" line in a pane that is about to disappear.
    while IFS= read -r pane; do
      tmux send-keys -t "$pane" Escape 2>/dev/null || true
      tmux send-keys -t "$pane" "/exit" C-m 2>/dev/null || true
      asked=$(( asked + 1 ))
    done < <(busy_panes "$sid")

    if (( asked )); then
      echo "asked $asked harness pane(s) to exit..." >&2
      # Poll rather than sleep a fixed time: a clean exit is usually immediate,
      # and a stuck one should not hold the close hostage either.
      while (( n < 100 )); do
        [[ -z $(busy_panes "$sid") ]] && break
        sleep 0.1
        n=$(( n + 1 ))
      done
      (( n < 100 )) || echo "note: a harness did not exit in 10s; closing anyway" >&2
    fi
  fi

  tmux kill-session -t "$sid"
  echo "closed $session" >&2
}

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") [config] [--attach|--detached|--recreate|--colors]
       $(basename "$0") new [dir] [--name <team>] [--detached]
       $(basename "$0") join <team> [dir] [--detached]
       $(basename "$0") close <team> [--no-save] [--force]
       $(basename "$0") save [team]
       $(basename "$0") --list
       $(basename "$0") --session <name> <config>

configs in $CONFIG_DIR: $(list_configs | paste -sd' ' -)
USAGE
}

# ---------------------------------------------------------------------- main ---
# Subcommands come first and parse their own arguments. A config named "new" or
# "join" would be shadowed; name one of those and use --session to reach it.
case "${1:-}" in
  new)   shift; cmd_new "$@";   exit 0 ;;
  join)  shift; cmd_join "$@";  exit 0 ;;
  close) shift; cmd_close "$@"; exit 0 ;;
  save)  shift; cmd_save "$@";  exit 0 ;;
esac

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
SESSION="${SESSION_OVERRIDE:-${SESSION_PREFIX}${CONFIG_NAME}}"

# A team built with `new` has no config file, but it is still a team: reaching it
# by name is the whole point of naming it. Only the modes that rebuild from a
# config need one.
if [[ ! -f $CONFIG_FILE ]]; then
  adhoc_sid="$(session_id "$SESSION")"
  if [[ -z $adhoc_sid ]]; then
    die "no such config or running team: $CONFIG_NAME" \
        "(configs: $(list_configs | paste -sd' ' -)" \
        "| running: $(list_adhoc | paste -sd' ' -))"
  fi
  case "$MODE" in
    attach)   attach "$adhoc_sid"; exit 0 ;;
    detached) exit 0 ;;   # asked for it running; it is
    *)        die "team '$CONFIG_NAME' has no config file; --$MODE rebuilds from one." \
                  "Run 'team save $CONFIG_NAME' first" ;;
  esac
fi

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
