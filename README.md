# tmux harness setup

Named configs, each one a tmux session with a window per folder, each window
running a harness, and a status bar whose colour is derived from the folder name.

## Files

| file | what it is |
|---|---|
| `configs/<name>.conf` | the files you edit: `name \| directory \| command` per window |
| `tmux-team.sh`  | builds or attaches to the session for a config |
| `install.sh`   | installs the `team` command and the boot-time user services |

## Ad-hoc teams

A config file is for a lineup you keep coming back to. For everything else,
build a team as you go:

```bash
cd ~/work/api
team new                      # team-api, one window, claude running in it
team new ~/work/api           # same, from anywhere
team new ~/work/api --name b2b  # call the team something else

cd ~/work/web
team join api                 # add this folder to team-api as a new window
team join api ~/work/worker   # or name the folder explicitly
```

Each window runs `claude --continue` when that folder has a resumable Claude
session and plain `claude` when it does not. The check is not "is there a
transcript file": a folder can hold transcripts from one-shot `-p`/SDK runs that
`--continue` refuses to resume, so it looks for at least one *interactive*
transcript and falls back to a fresh session otherwise. A window that opens on
"No conversation found to continue" is worse than one that just starts clean.

Reach a team afterwards the same way as a config-backed one — `team api` attaches,
`team --list` shows it as `(ad-hoc)`, and it appears in the menu `team` offers with
no argument. `--recreate` and `--colors` are the exception: they rebuild from a
config file, so they refuse a team that has none.

`join` refuses a folder that is already a window in that team — two windows on
one folder would both `--continue` the same transcript — and refuses a team that
is not running, rather than quietly creating it. Teams made this way have no
config file, so `--list` shows them as `(ad-hoc)`.

Both take `--detached` to build without attaching.

## Configs

Each `configs/<name>.conf` owns a session called **`team-<name>`**. The `team-`
prefix keeps these clear of the per-project sessions you run outside this tool —
without it a config named `api` would collide with an existing `api`
session. Change `SESSION_PREFIX` at the top of `tmux-team.sh` (or set
`TMUX_TEAM_PREFIX`) if you want a different one; avoid `[` and `]`, which are
fnmatch metacharacters in tmux targets and glob characters in your shell.

Ships with one config, `configs/example.conf`. Copy it, rename it, edit it:

| config | session | windows |
|---|---|---|
| `example` | `team-example` | api, web, worker, notes — a `claude` session per project, plus an editor |

### Globs

The directory field may be a glob, which becomes **one window per matching
directory** — so a config tracks a tree instead of freezing today's contents:

```
* | ~/work/services/*/ | claude --continue --permission-mode auto
```

A window name of `*` means "use the folder's own name". Add or remove a subfolder
and `team example --recreate` picks up the change with no edit to the config. A
glob that matches nothing is reported and skipped, like a missing directory; the
rest of the config still loads. Expansion is unquoted, so paths with spaces need
a literal line rather than a glob.

Note: `--auto` is not a claude flag — `auto` is a *permission mode*, hence
`--permission-mode auto`. `claude --continue --auto` exits immediately with
`error: unknown option '--auto'`.

## Usage

```sh
./install.sh                  # once: symlink ~/.local/bin/team + enable each config at boot
./install.sh example          # ...or enable only some configs
team                           # pick a config from a menu, then attach
team example                   # attach (creates the session first if it is not running)
team new [dir]                 # start a team of one from a folder (no config file)
team join <team> [dir]         # add a folder to a team that is already running
team example --recreate          # pick up config changes
team --list                    # configs, their sessions, and what is running
team example --colors          # show the folder -> colour mapping
team example --detached        # create without attaching (what systemd runs)
team --session foo example     # override the session name for a one-off
```

With no config named, `team` shows a numbered menu; if there is only one config it
picks it. Without a TTY (systemd) it refuses rather than hanging. `team` works from
inside tmux too — it does `switch-client` instead of `attach`.

## Bar colour

The basename of each window's directory is hashed (`cksum`) into a 48-entry
palette of 256-colour indices that are light enough to carry black text. The
colour is stored on the window as the user option `@barcolor`, and the session's
`status-style` is set to a *format* rather than a literal:

```
status-style "bg=#{?@barcolor,#{@barcolor},colour244},fg=colour232"
```

tmux expands `#{}` inside styles against the client's current window on every
redraw, so the bar recolours itself as you move between windows with no hooks
and no polling. `pane-active-border-style` follows the same colour.

The mapping is pure and stable: the same folder name always yields the same
colour, on any machine, across reboots.

## Windows

`windows.conf` entries are validated — a line pointing at a missing directory is
skipped with a warning rather than aborting the session. Commands are *typed into
the window's shell* rather than exec'd, so quitting the harness (or its crashing)
leaves you with a usable shell in the right directory instead of a dead window.
The launcher waits for each shell to draw its prompt before typing, so nothing is
echoed by the bare pty.

## Option scoping (the one real trap)

Settings are applied to this session only, never globally, so your `~/.tmux.conf`
and your other sessions are untouched. But tmux splits them into two namespaces
and it is easy to get wrong:

* **Session options** — `status*`, `mouse`, `base-index`, `history-limit`,
  `renumber-windows`. Set once with `set -t <session-id>` (`style_session`).
* **Window options** — `window-status-format`, `window-status-current-format`,
  `window-status-separator`, `window-status-*-style`, `pane-border-style`,
  `pane-active-border-style`, `allow-rename`, `automatic-rename`. These must be
  set with `set -t <window-id> -w`, **once per window** (`style_window`) — or,
  where the value should apply everywhere, once with `setw -g` in
  `~/.tmux.conf`, which every window in every session then inherits.

`set -t <session-id> window-status-format …` does not error — it silently lands
on that session's *current window*, leaving every other window on the global
default. The visible symptom is a status bar where one window highlights with a
reversed background and the rest fall back to tmux's `1:name*`. Check with
`tmux show -w -t <window-id> -v window-status-format` per window, not with
`show -t <session>`.

Because window options are per window, a window you create by hand would miss
them, so the session carries an `after-new-window` hook that runs
`tmux-team.sh --style-window "#{window_id}"`. New windows inherit the current
directory, so they also get a bar colour hashed from wherever they open.

## Window flags

The current window is shown by reversing the bar colour, not by tmux's default
`*`. This one is wanted in *every* session, not just `team`, so it lives in
`~/.tmux.conf` as a global window default rather than being applied by the
launcher:

```tmux
setw -g window-status-separator ""
setw -g window-status-format " #I #W#{s/[-*]//:window_flags} "
setw -g window-status-current-format "#[reverse,bold] #I #W#{s/[-*]//:window_flags} #[noreverse,nobold]"
```

`style_window` therefore only sets what genuinely has to differ per window
(`@barcolor` and the pane borders derived from it). The formats keep the
*informative* flags and drop the redundant ones:

`#{s/[-*]//:…}` strips `*` (current — already conveyed by the highlight) and `-`
(last window), while leaving `Z` zoomed, `#` activity, `!` bell, `~` silence and
`M` marked. Without that substitution a zoomed pane gives you no indication at
all that the window is zoomed.

## Boot

`install.sh` writes a single templated unit,
`~/.config/systemd/user/tmux-team@.service`, instantiated once per config
(`tmux-team@example`, `tmux-team@example`):

* `Type=oneshot` + `RemainAfterExit=yes` — the unit represents "the session exists".
* `KillMode=process` — the tmux server daemonises out of the unit's main process,
  so only that process is signalled on stop; `ExecStop` does the real teardown
  with `tmux kill-session`.
* `WantedBy=default.target` — started with your user manager.

It also enables *lingering* for your account (`loginctl enable-linger`). Without
lingering, the user manager only exists while you are logged in, so the session
would be created at your first login rather than at boot. If enabling it needs
authentication, run `sudo loginctl enable-linger $USER` yourself.

```sh
systemctl --user status  tmux-team@example
systemctl --user restart tmux-team@example     # rebuild from the config
systemctl --user disable --now tmux-team@example # stop starting this one at boot
```

## Adding a harness

Append a line to the config and run `team <config> --recreate`. Anything on `$PATH`
works; the launcher prepends `~/.local/bin`, `~/.opencode/bin` and `~/bin` so
per-tool install dirs are visible to the non-login systemd unit as well.

## A note on session targeting

You already keep one tmux session per project, named after the folder. tmux
resolves a `-t name` target by *prefix and pattern*, so `-t team` also matches
every session this tool creates, `team-example` included — and `set -t`/`display
-t` do not honour the `=exact`
prefix in tmux 3.4 either. Everything here therefore looks the session up by
exact name once and then targets it by **session id** (`$38`), which is
unambiguous. If you rename the session (`TMUX_TEAM_SESSION`), no other session can
be caught in the blast radius.

## Cmd+Left / Cmd+Right to switch windows

macOS keeps the Command modifier for itself — it never reaches the terminal's
byte stream, so tmux cannot bind it directly. iTerm2 has to be told to *send*
something for the chord, and tmux binds that instead. Two halves:

**iTerm2** — Settings → Profiles → Keys → Key Mappings → `+`

| Shortcut | Action | Escape sequence |
|---|---|---|
| ⌘← | Send Escape Sequence | `[9001~` |
| ⌘→ | Send Escape Sequence | `[9002~` |

(If the *Natural Text Editing* preset is loaded it already binds ⌘←/⌘→ to
Home/End — overwrite those two entries.)

**tmux** — in `~/.tmux.conf`, server-wide so it works in every session:

```tmux
set -s user-keys[0] "\e[9001~"
set -s user-keys[1] "\e[9002~"
bind -n User0 previous-window
bind -n User1 next-window
```

`CSI 9001 ~` is outside the range any real key produces, so it cannot collide
with a genuine key report — unlike reusing something like `\e[1;9D`, which is a
legitimate Meta+Left. `bind -n` puts them in the root table, so they need no
prefix and fire even while claude or opencode has the pane; ordinary arrow keys
are untouched and still reach the application.

Note that `user-keys` only expands `\e` when tmux parses it from a config file —
setting it from a shell (`tmux set -s user-keys[0] '\e[9001~'`) stores a literal
backslash-e and silently never matches.
