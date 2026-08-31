#!/usr/bin/env bash
# Launch a named harness config as its own tmux session.
#
#   tmux-team.sh                    pick a config, then attach
#   tmux-team.sh <config>           create if needed, then attach
#   tmux-team.sh new [dir]          start a team of one from a folder
#   tmux-team.sh join <team> [dir]  add a folder to an existing team
#                                   both take --cmd to run something other than claude
#   tmux-team.sh remove <team> <name>  drop one window from a team
#   tmux-team.sh close <team>       shut a team down, keeping sessions resumable
#   tmux-team.sh --list             list configs and whether they are running
#   tmux-team.sh [config] --colors  print the folder -> colour mapping
#
# Configs live in configs/<name>.json and each one owns a session called
# "team-<name>", so these never collide with the per-project sessions you keep
# outside this tool. Every tmux command targets the session by *id* ($0, $1, ...)
# because tmux resolves a name target by prefix and pattern.

set -euo pipefail

# Resolve through the ~/.local/bin symlink so configs/ is found next to the real
# script. Done by hand because `readlink -f` is GNU-only: macOS ships BSD
# readlink, which has no -f and would leave HERE pointing at ~/.local/bin.
_resolve() {
  local p="$1" d
  while [[ -L $p ]]; do
    d="$(cd "$(dirname "$p")" && pwd)"
    p="$(readlink "$p")"
    [[ $p == /* ]] || p="$d/$p"
  done
  printf '%s\n' "$p"
}
HERE="$(cd "$(dirname "$(_resolve "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${TMUX_TEAM_CONFIG_DIR:-$HERE/configs}"
SESSION_PREFIX="${TMUX_TEAM_PREFIX-team-}"

# Harnesses live in per-tool bin dirs that a non-login systemd unit or a launchd
# agent does not have; /opt/homebrew and /usr/local cover tmux and claude on
# macOS, where launchd hands the job a minimal PATH.
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# ---------------------------------------------------------------- bar colours --
# 256-colour indices, all light enough to carry black text.
PALETTE=(
  32  33  38  39  40  41  42  43  68  69  70  71  74  75  76  77
  80  81 105 108 110 111 113 114 132 138 140 143 146 149 150 152
 168 173 174 175 178 179 180 181 209 210 211 214 215 216 220 222
)

# palette_index <string> -> the xterm colour number that string always maps to.
palette_index() {
  local h
  h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s' "${PALETTE[$(( h % ${#PALETTE[@]} ))]}"
}

# barcolor <folder-name> -> "colourNNN"; stable across machines and reboots.
barcolor() {
  printf 'colour%s' "$(palette_index "$1")"
}

# xterm_rgb <index> -> "R G B" for an xterm-256 colour number.
xterm_rgb() {
  local i="$1" r g b
  local -a levels=(0 95 135 175 215 255)
  if (( i >= 16 && i <= 231 )); then
    i=$(( i - 16 ))
    r="${levels[$(( i / 36 ))]}"; g="${levels[$(( (i % 36) / 6 ))]}"; b="${levels[$(( i % 6 ))]}"
  else
    r=$(( 8 + 10 * (i - 232) )); g="$r"; b="$r"
  fi
  printf '%s %s %s' "$r" "$g" "$b"
}

# tab_color <team-name>: paint the terminal tab from the team's name, using the
# same palette the window bars come from, so a team is one colour end to end.
#
# OSC 6 is iTerm2's own sequence. Other terminals would ignore it, but a stray
# escape is not worth the risk, so it goes out only when iTerm2 says it is there:
# LC_TERMINAL is set by iTerm2 and forwarded over ssh, which is what makes this
# work from a Mac into a Linux box. TMUX_TEAM_TAB_COLOR=0 turns it off.
tab_color() {
  [[ ${TMUX_TEAM_TAB_COLOR:-1} == 1 ]] || return 0
  [[ ${LC_TERMINAL:-} == iTerm2 || ${TERM_PROGRAM:-} == iTerm.app ]] || return 0
  local rgb r g b seq
  rgb="$(xterm_rgb "$(palette_index "$1")")"
  read -r r g b <<<"$rgb"
  printf -v seq '\033]6;1;bg;red;brightness;%d\a\033]6;1;bg;green;brightness;%d\a\033]6;1;bg;blue;brightness;%d\a' \
    "$r" "$g" "$b"
  if [[ -n ${TMUX:-} ]]; then
    # Inside tmux the sequence has to be smuggled out to the real terminal.
    tmux set -g allow-passthrough on 2>/dev/null || true
    printf '\033Ptmux;%s\033\\' "${seq//$'\033'/$'\033\033'}" >/dev/tty 2>/dev/null || true
  else
    printf '%s' "$seq" >/dev/tty 2>/dev/null || true
  fi
}

# ------------------------------------------------------------------- helpers ---
die() { echo "error: $*" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

list_configs() {
  local f
  for f in "$CONFIG_DIR"/*.json; do
    [[ -e $f ]] || continue
    basename "$f" .json
  done
}

# Running team- sessions with no config file behind them.
list_unconfigured() {
  local name
  while IFS= read -r name; do
    [[ $name == "$SESSION_PREFIX"* ]] || continue
    name="${name#$SESSION_PREFIX}"
    [[ -f "$CONFIG_DIR/$name.json" ]] || printf '%s\n' "$name"
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

# --------------------------------------------------------------- config file --
# A config is JSON: { "windows": [ { "name":…, "dir":…, "cmd":… }, … ] }.
#
#   dir   required; ~ is expanded, and a glob becomes one window per match
#   name  optional, defaults to the folder's name; "*" means the same thing and
#         is the useful spelling for a glob
#   cmd   optional; absent or "" opens the window with no command
#
# Parsing and writing both go through python3 rather than jq: python3 is present
# by default on macOS and Ubuntu where jq is not, and it escapes strings
# correctly when writing - a path or command with a quote in it would otherwise
# produce a config the tool cannot read back.
config_py() {
  python3 - "$@" <<'PYEOF'
import glob, json, os, sys

def load(path):
    with open(path) as fh:
        doc = json.load(fh)
    if isinstance(doc, list):          # a bare array of windows is fine too
        doc = {"windows": doc}
    if not isinstance(doc, dict) or not isinstance(doc.get("windows"), list):
        raise ValueError('expected {"windows": [ ... ]}')
    return doc

def emit(path):
    """Print name<TAB>dir<TAB>cmd per usable window; warn about the rest."""
    try:
        doc = load(path)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"skip: {os.path.basename(path)}: {e}", file=sys.stderr)
        return 1
    for w in doc["windows"]:
        if not isinstance(w, dict) or not w.get("dir"):
            print(f"skip: window with no dir: {w!r}", file=sys.stderr)
            continue
        raw = os.path.expanduser(str(w["dir"]))
        name = str(w.get("name") or "*")
        cmd = str(w.get("cmd") or "")
        if any(c in raw for c in "*?["):
            matches = sorted(d.rstrip("/") for d in glob.glob(raw) if os.path.isdir(d))
            if not matches:
                print(f"skip: '{name}' -> nothing matches: {raw}", file=sys.stderr)
                continue
            for m in matches:
                print("\t".join([os.path.basename(m) if name == "*" else name, m, cmd]))
            continue
        raw = raw.rstrip("/") or "/"
        if not os.path.isdir(raw):
            print(f"skip: '{name}' -> no such directory: {raw}", file=sys.stderr)
            continue
        print("\t".join([os.path.basename(raw) if name == "*" else name, raw, cmd]))
    return 0

def window(d, cmd):
    home = os.path.expanduser("~")
    short = "~" + d[len(home):] if d == home or d.startswith(home + os.sep) else d
    w = {"name": os.path.basename(d), "dir": short}
    if cmd:
        w["cmd"] = cmd
    return w

def write(path, doc):
    with open(path, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")

mode = sys.argv[1]
if mode == "read":
    sys.exit(emit(sys.argv[2]))
elif mode == "create":
    write(sys.argv[2], {"windows": [window(sys.argv[3], sys.argv[4])]})
elif mode == "append":
    doc = load(sys.argv[2])
    doc["windows"].append(window(sys.argv[3], sys.argv[4]))
    write(sys.argv[2], doc)
elif mode in ("remove", "check_remove"):
    # Match a literal entry only: a window that came from a glob has no entry of
    # its own, and dropping the glob would take its siblings with it.
    #
    # check_remove answers the same question without writing, so the caller can
    # refuse before it asks a harness to quit. Exit 1: nothing matched. Exit 2:
    # that is the only window.
    path, target = sys.argv[2], sys.argv[3]
    doc = load(path)
    keep, dropped = [], 0
    for w in doc["windows"]:
        d = os.path.expanduser(str(w.get("dir", "")))
        name = str(w.get("name") or os.path.basename(d.rstrip("/")))
        if name == target and not any(c in d for c in "*?["):
            dropped += 1
            continue
        keep.append(w)
    if not dropped:
        sys.exit(1)
    if not keep:
        sys.exit(2)
    if mode == "remove":
        doc["windows"] = keep
        write(path, doc)
else:
    print(f"unknown mode: {mode}", file=sys.stderr)
    sys.exit(2)
PYEOF
}

# Emits "name<TAB>dir<TAB>command" per usable window; warns about the rest.
read_config() {
  config_py read "$CONFIG_FILE"
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
  local sid="$1" sname
  sname="$(tmux display -p -t "$sid" '#{session_name}' 2>/dev/null || true)"
  [[ -z $sname ]] || tab_color "${sname#$SESSION_PREFIX}"
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
        "$(CONFIG_FILE="$CONFIG_DIR/$c.json" read_config 2>/dev/null | cut -f1 | paste -sd, -)"
    fi
  done

  # A team- session the tool cannot explain - config deleted, made by hand, or
  # built with --session - should be visible rather than hidden.
  while IFS=$'\t' read -r s sid; do
    [[ $s == "$SESSION_PREFIX"* ]] || continue
    c="${s#$SESSION_PREFIX}"
    [[ -f "$CONFIG_DIR/$c.json" ]] && continue
    printf '%-16s %-18s %-9s %s\n' "(no config)" "$s" running \
      "$(tmux list-windows -t "$sid" -F '#{window_name}' | paste -sd, -)"
  done < <(tmux list-sessions -F '#{session_name}	#{session_id}' 2>/dev/null)
}

# Ask which config to load, when none was named on the command line.
pick_config() {
  local -a cfgs=(); local c n reply
  # A read loop rather than `mapfile`, which is bash 4+: macOS ships bash 3.2.
  while IFS= read -r c; do cfgs+=("$c"); done < <(list_configs; list_unconfigured)
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

# team new [dir] [--name <team>] [--cmd <command>]: start a team from one folder.
#
# This writes configs/<name>.json and then builds it through the same path as any
# other team. Teams used to exist as tmux state alone, which made them a second
# class the rest of the tool had to special-case; a team is a config, full stop.
cmd_new() {
  local dir='' name='' cmd=''
  while (( $# )); do
    case "$1" in
      --name)      name="${2:-}"; shift ;;
      --cmd)       cmd="${2:-}"; shift ;;
      -h|--help)   echo "usage: $(basename "$0") new [dir] [--name <team>] [--cmd <command>]" >&2; exit 0 ;;
      -*)          die "unknown option: $1" ;;
      *)           dir="$1" ;;
    esac
    shift
  done

  dir="$(cd "${dir:-$PWD}" 2>/dev/null && pwd)" || die "no such directory: ${dir:-$PWD}"
  name="${name:-$(basename "$dir")}"
  CONFIG_NAME="$name"
  CONFIG_FILE="$CONFIG_DIR/$name.json"
  SESSION="${SESSION_PREFIX}${name}"

  [[ -z $(session_id "$SESSION") ]] \
    || die "$SESSION is already running - 'team join $name $dir' to add this folder, or 'team $name' to attach"
  [[ ! -f $CONFIG_FILE ]] \
    || die "config '$name' already exists - 'team $name' to start it, or pass --name for a different team"

  # With no --cmd, record what this folder should run: claude, resuming its
  # session when there is one. Deciding here rather than at build time is what
  # keeps a config honest about what it starts.
  [[ -n $cmd ]] || cmd="$(claude_cmd "$dir")"
  config_py create "$CONFIG_FILE" "$dir" "$cmd"
  echo "wrote $CONFIG_FILE" >&2

  attach "$(ensure_session)"
}

# team join <team> [dir] [--cmd <command>]: add a folder to a team.
#
# The folder is appended to the team's config, so it is part of the team the next
# time it is built, and added as a live window when the team is running now.
cmd_join() {
  local team='' dir='' cmd=''
  while (( $# )); do
    case "$1" in
      --cmd)       cmd="${2:-}"; shift ;;
      -h|--help)   echo "usage: $(basename "$0") join <team> [dir] [--cmd <command>]" >&2; exit 0 ;;
      -*)          die "unknown option: $1" ;;
      *)           if [[ -z $team ]]; then team="$1"; else dir="$1"; fi ;;
    esac
    shift
  done

  [[ -n $team ]] || die "usage: $(basename "$0") join <team> [dir]"
  dir="$(cd "${dir:-$PWD}" 2>/dev/null && pwd)" || die "no such directory: ${dir:-$PWD}"

  local name="${team#$SESSION_PREFIX}"
  CONFIG_NAME="$name"
  CONFIG_FILE="$CONFIG_DIR/$name.json"
  SESSION="${SESSION_PREFIX}${name}"
  local sid; sid="$(session_id "$SESSION")"

  if [[ ! -f $CONFIG_FILE ]]; then
    [[ -z $sid ]] \
      && die "no team called '$name' - 'team new $dir --name $name' to start one"
    # A team- session the tool did not create (made by hand, or via --session):
    # appending to a config it has no idea about would invent a lineup.
    die "'$name' is running but has no config; the tool cannot tell what is in it"
  fi

  # Two windows on one folder would both --continue the same transcript.
  grep -Fxq "$dir" <(config_dirs "$CONFIG_FILE") \
    && die "$dir is already in team '$name'"
  [[ -n $cmd ]] || cmd="$(claude_cmd "$dir")"
  config_py append "$CONFIG_FILE" "$dir" "$cmd"
  echo "added $(basename "$dir") to $CONFIG_FILE" >&2

  if [[ -z $sid ]]; then
    echo "team '$name' is not running - 'team $name' to start it" >&2
    return 0
  fi

  local wid; wid="$(add_window "$sid" "$dir" "$cmd")"
  tmux select-window -t "$wid"
  attach "$sid"
}

# busy_panes <list-panes target args>: panes running something other than a
# login shell - i.e. a live harness. The caller passes the scope, because both
# `-s -t <session>` and `-t <window>` are wanted and `-s` with a window id would
# quietly widen back to the whole session.
busy_panes() {
  { tmux list-panes "$@" -F '#{pane_id} #{pane_current_command}' 2>/dev/null \
    | awk '$2 != "bash" && $2 != "zsh" && $2 != "sh" && $2 != "fish" && $2 != "dash" { print $1 }'; } || true
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
# Add one window for <dir> to session <sid>, running <command> - or claude,
# resuming where it can, when none is given.
add_window() {
  local sid="$1" dir="$2" cmd="${3:-}" wid
  [[ -n $cmd ]] || cmd="$(claude_cmd "$dir")"
  wid=$(tmux new-window -t "$sid:" -n "$(basename "$dir")" -c "$dir" -P -F '#{window_id}')
  style_window "$wid"
  wait_for_prompt "$wid"
  tmux send-keys -t "$wid" "$cmd" C-m
  printf '%s\n' "$wid"
}

# Directories a config already lists, one per line.
config_dirs() {
  [[ -f $1 ]] || return 0
  CONFIG_FILE="$1" read_config 2>/dev/null | cut -f2
}

# team remove <team> <name> [--force]: drop one window from a team.
#
# The entry goes out of the config and the live window is closed, harness first.
# A team's last window is refused - a config with no windows builds nothing, so
# that is `close` wearing a different name.
cmd_remove() {
  local team='' target='' force=0
  while (( $# )); do
    case "$1" in
      --force)    force=1 ;;
      -h|--help)  echo "usage: $(basename "$0") remove <team> <name> [--force]" >&2; exit 0 ;;
      -*)         die "unknown option: $1" ;;
      *)          if [[ -z $team ]]; then team="$1"; else target="$1"; fi ;;
    esac
    shift
  done
  [[ -n $team && -n $target ]] || die "usage: $(basename "$0") remove <team> <name>"

  local name="${team#$SESSION_PREFIX}"
  CONFIG_NAME="$name"
  CONFIG_FILE="$CONFIG_DIR/$name.json"
  SESSION="${SESSION_PREFIX}${name}"
  [[ -f $CONFIG_FILE ]] || die "no team called '$name'"

  local sid; sid="$(session_id "$SESSION")"

  # Ask what would happen before doing anything: refusing after having told a
  # harness to quit would cost the user a session for nothing.
  local rc=0
  config_py check_remove "$CONFIG_FILE" "$target" || rc=$?
  if (( rc == 1 )); then
    if read_config 2>/dev/null | cut -f1 | grep -Fxq "$target"; then
      die "'$target' comes from a glob entry, which covers several folders;" \
          "edit $CONFIG_FILE to narrow or drop that entry"
    fi
    die "no window called '$target' in team '$name'" \
        "(have: $(read_config 2>/dev/null | cut -f1 | paste -sd' ' -))"
  fi
  (( rc == 2 )) && die "'$target' is the team's only window - 'team close $name' instead"

  local wid=''
  if [[ -n $sid ]]; then
    wid="$(tmux list-windows -t "$sid" -F '#{window_id} #{window_name}' 2>/dev/null \
           | awk -v n="$target" '$2 == n { print $1; exit }' || true)"
  fi
  if [[ -n $wid ]] && (( ! force )); then
    local pane n=0
    while IFS= read -r pane; do
      tmux send-keys -t "$pane" Escape 2>/dev/null || true
      tmux send-keys -t "$pane" "/exit" C-m 2>/dev/null || true
    done < <(busy_panes -t "$wid")
    while (( n < 100 )); do
      [[ -z $(busy_panes -t "$wid") ]] && break
      sleep 0.1
      n=$(( n + 1 ))
    done
    (( n < 100 )) || echo "note: the harness did not exit in 10s; closing anyway" >&2
  fi

  config_py remove "$CONFIG_FILE" "$target"
  [[ -z $wid ]] || tmux kill-window -t "$wid"
  echo "removed '$target' from $CONFIG_FILE" >&2
  [[ -n $wid ]] && echo "closed its window" >&2
  return 0
}

# team close <team> [--force]: shut a team down and forget it.
#
# Closing removes every trace of the team: its tmux session and its config file,
# which together are all there is - the boot service starts whatever configs are
# present, so a deleted config simply never comes back. What it does not touch is the Claude transcripts in
# ~/.claude/projects - those belong to the folders, not to the team, so a later
# `team new <dir>` picks each one up again with --continue.
#
# Each harness is asked to /exit first and given time to go. Claude appends its
# transcript as it goes and would usually survive a kill, but "usually" is the
# wrong standard for the state you most want back.
cmd_close() {
  local team='' force=0
  while (( $# )); do
    case "$1" in
      --force)    force=1 ;;
      -h|--help)  echo "usage: $(basename "$0") close <team> [--force]" >&2; exit 0 ;;
      -*)         die "unknown option: $1" ;;
      *)          team="$1" ;;
    esac
    shift
  done

  # Deliberately no implicit target: closing a team is not the kind of thing to
  # infer from where the shell happens to be sitting.
  [[ -n $team ]] || die "usage: $(basename "$0") close <team>"

  local name="${team#$SESSION_PREFIX}"
  local session="${SESSION_PREFIX}${name}"
  local cfg="$CONFIG_DIR/$name.json"
  local sid; sid="$(session_id "$session")"

  [[ -n $sid || -f $cfg ]] || die "no team called '$name'"

  if [[ -n $sid ]]; then
    if (( ! force )); then
      local pane n=0 asked=0
      # Anything that is not a bare shell is treated as a harness worth asking.
      # Matching on the command being exactly "claude" would miss it the moment
      # it runs behind a wrapper, and the cost of asking a non-harness is one
      # "command not found" line in a pane that is about to disappear.
      while IFS= read -r pane; do
        tmux send-keys -t "$pane" Escape 2>/dev/null || true
        tmux send-keys -t "$pane" "/exit" C-m 2>/dev/null || true
        asked=$(( asked + 1 ))
      done < <(busy_panes -s -t "$sid")

      if (( asked )); then
        echo "asked $asked harness pane(s) to exit..." >&2
        # Poll rather than sleep a fixed time: a clean exit is usually immediate,
        # and a stuck one should not hold the close hostage either.
        while (( n < 100 )); do
          [[ -z $(busy_panes -s -t "$sid") ]] && break
          sleep 0.1
          n=$(( n + 1 ))
        done
        (( n < 100 )) || echo "note: a harness did not exit in 10s; closing anyway" >&2
      fi
    fi
    tmux kill-session -t "$sid"
    echo "closed $session" >&2
  fi

  # Deleting the config is all it takes to keep the team from coming back: the
  # boot service builds whatever configs exist, so there is no per-team unit to
  # disable.
  # An `if`, not `[[ ]] && { }`: as the last statement in the function the latter
  # returns 1 when there is no config, which `set -e` turns into a silent failure
  # after the work is already done.
  if [[ -f $cfg ]]; then
    rm -f "$cfg"
    echo "removed $cfg" >&2
  fi
}

# Build every config, skipping teams already up. This is what the boot service
# runs: one unit for all teams, so adding a team is writing a config and nothing
# else, and closing one is deleting it.
cmd_boot() {
  local c built=0
  for c in $(list_configs); do
    CONFIG_NAME="$c"
    CONFIG_FILE="$CONFIG_DIR/$c.json"
    SESSION="${SESSION_PREFIX}${c}"
    if [[ -n $(session_id "$SESSION") ]]; then
      echo "$SESSION already running" >&2
      continue
    fi
    # One broken config must not stop the rest from coming up. Trust the result,
    # not the exit status: ensure_session runs with `set -e` suppressed here, so
    # a failed build still returns 0 - ask tmux whether the session exists.
    ensure_session >/dev/null || true
    if [[ -n $(session_id "$SESSION") ]]; then
      echo "started $SESSION" >&2
      built=$(( built + 1 ))
    else
      echo "failed to start $SESSION" >&2
    fi
  done
  echo "$built team(s) started" >&2
}

# Kill every team session, leaving the configs alone: this is a shutdown, not a
# close. `team close` is the one that forgets a team.
cmd_stop_all() {
  local s sid
  while IFS=$'\t' read -r s sid; do
    [[ $s == "$SESSION_PREFIX"* ]] || continue
    tmux kill-session -t "$sid" 2>/dev/null || true
    echo "stopped $s" >&2
  done < <(tmux list-sessions -F '#{session_name}	#{session_id}' 2>/dev/null || true)
}

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") [team] [--colors]
       $(basename "$0") new [dir] [--name <team>] [--cmd <command>]
       $(basename "$0") join <team> [dir] [--cmd <command>]
       $(basename "$0") remove <team> <name> [--force]
       $(basename "$0") close <team> [--force]
       $(basename "$0") --boot | --stop-all
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
  close)  shift; cmd_close "$@";  exit 0 ;;
  remove) shift; cmd_remove "$@"; exit 0 ;;
  --boot)     shift; cmd_boot "$@";     exit 0 ;;
  --stop-all) shift; cmd_stop_all "$@"; exit 0 ;;
esac

MODE=attach; CONFIG_NAME=''; SESSION_OVERRIDE=''; STYLE_WID=''
while (( $# )); do
  case "$1" in
    --list)                MODE=list ;;
    --colors|--colours)    MODE=colors ;;
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
CONFIG_FILE="$CONFIG_DIR/$CONFIG_NAME.json"
SESSION="${SESSION_OVERRIDE:-${SESSION_PREFIX}${CONFIG_NAME}}"

# `new` and `join` keep a config for every team they touch, but a running
# team- session can still have none: its config deleted, made by hand, or built
# with --session. Attaching to it by name should work anyway; only the modes that
# rebuild from a config need one.
if [[ ! -f $CONFIG_FILE ]]; then
  orphan_sid="$(session_id "$SESSION")"
  if [[ -z $orphan_sid ]]; then
    die "no such config or running team: $CONFIG_NAME" \
        "(configs: $(list_configs | paste -sd' ' -)" \
        "| running: $(list_unconfigured | paste -sd' ' -))"
  fi
  case "$MODE" in
    attach) attach "$orphan_sid"; exit 0 ;;
    *)      die "team '$CONFIG_NAME' has no config file, and --$MODE reads one" ;;
  esac
fi

case "$MODE" in
  colors)
    while IFS=$'\t' read -r name dir cmd; do
      printf '%-16s %-34s %s\n' "$name" "$dir" "$(barcolor "$(basename "$dir")")"
    done < <(read_config) ;;
  attach)
    attach "$(ensure_session)" ;;
esac
