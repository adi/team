# tmux harness setup

Named configs, each one a tmux session with a window per folder, each window
running a harness, and a status bar whose colour is derived from the folder name.

## Files

| file | what it is |
|---|---|
| `configs/<name>.conf` | the files you edit: `name \| directory \| command` per window |
| `tmux-team.sh`  | builds or attaches to the session for a config |
| `install.sh`   | installs the `team` command and the login-time service (systemd or launchd) |

## Teams on the fly

A team *is* a config file. `new` and `join` write one for you, so a team you
build in ten seconds behaves exactly like one you hand-wrote — every command
works on it, and it survives a reboot.

```bash
cd ~/work/api
team new                      # writes configs/api.conf, starts team-api
team new ~/work/api --name b2b  # call the team something else

cd ~/work/web
team join api                 # appends this folder, adds a live window
team join api ~/work/worker   # or name the folder explicitly

team close api                # shut it down, leaving every session resumable
team api                      # ...and bring it back, resuming each folder
```

Each window runs `claude --continue` when that folder has a resumable Claude
session and plain `claude` when it does not. The check is not "is there a
transcript file": a folder can hold transcripts from one-shot `-p`/SDK runs that
`--continue` refuses to resume, so it looks for at least one *interactive*
transcript. A window that opens on "No conversation found to continue" is worse
than one that starts clean. `join` decides per folder, at the moment it writes
the line.

`close` always takes a team name — it will not infer one from the session you
happen to be sitting in. It asks every non-shell pane to `/exit` and waits for it to go — up to ten
seconds, then closes anyway — so each harness saves its own state rather than
being killed mid-write. Claude appends its transcript as it goes and would
usually survive a kill, but "usually" is the wrong standard for the thing you
most want back. `--force` skips the asking.

`join` refuses a folder already in the team — two windows would both `--continue`
the same transcript.

A `team-` session the tool cannot explain — its config deleted, or a session you
made by hand — shows as `(no config)` in `--list`. It can be attached and closed,
but not joined: without a config there is nothing that says what the team is, and
guessing from the live windows would invent a lineup you never wrote. `close`
never writes a config; it warns that the lineup is not recoverable and closes.

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
team new [dir]                 # write a config for a folder and start it
team join <team> [dir]         # add a folder to a team (config + live window)
team close <team>             # shut a team down, keeping sessions resumable
team example --recreate          # pick up config changes
team --list                    # configs, their sessions, and what is running
team example --colors          # show the folder -> colour mapping
team example --detached        # create without attaching (what the service does)
team --session foo example     # override the session name for a one-off
```

With no config named, `team` shows a numbered menu; if there is only one config it
picks it. Without a TTY (a service) it refuses rather than hanging. `team` works from
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

## Starting at login

One service builds every config. There is deliberately no service per team: a
team is a config file, so adding one is writing a config and closing one is
deleting it — neither needs the init system told, and a config can never be
enabled while missing, or missing while enabled.

**Linux (systemd).** `install.sh` writes
`~/.config/systemd/user/tmux-team.service`:

* `ExecStart=tmux-team.sh --boot` — one session per config, skipping any already
  running; one broken config does not stop the rest.
* `ExecStop=tmux-team.sh --stop-all` — kills the team sessions and leaves the
  configs alone. Stopping is not closing.
* `Type=oneshot` + `RemainAfterExit=yes` — the unit represents "the teams exist".
* `KillMode=process` — the tmux server daemonises out of the unit's main process,
  so only that process is signalled and `ExecStop` does the real teardown.

It also enables *lingering* (`loginctl enable-linger`), without which the user
manager only exists while you are logged in and the teams would start at first
login rather than at boot.

```sh
systemctl --user status  tmux-team
systemctl --user restart tmux-team     # rebuild whatever is missing
```

**macOS (launchd).** `install.sh` writes
`~/Library/LaunchAgents/com.adi.team.plist` with `RunAtLoad`, and loads it with
`launchctl bootstrap gui/$UID` (falling back to `load -w` on older systems).

A LaunchAgent runs at **login**, not at boot: macOS has no per-user equivalent of
lingering, and there is no user session to own a tmux server beforehand. Output
goes to `~/Library/Logs/team.log`, since a launchd job has no terminal.

```sh
launchctl kickstart -k gui/$UID/com.adi.team   # rebuild whatever is missing
launchctl bootout gui/$UID/com.adi.team        # stop starting teams at login
tail -f ~/Library/Logs/team.log
```

Either way, `team --boot` does the same thing by hand.

## Portability

Runs on Linux and macOS. Requirements are tmux, bash, and whatever harness your
configs name.

* **Stock macOS bash is 3.2**, so nothing here uses bash 4 features — no
  `mapfile`, no associative arrays.
* **`readlink -f` is GNU-only.** The script resolves its own symlink by hand, so
  `~/.local/bin/team` still finds `configs/` next to the real file.
* **`PATH` for a launchd or systemd job is minimal**, so the script prepends
  `~/.local/bin`, `~/.opencode/bin`, `~/bin`, `/opt/homebrew/bin` and
  `/usr/local/bin` — where tmux and claude actually live.
* Window bar colours come from `cksum`, which is POSIX CRC32 on both platforms,
  so a folder keeps the same colour on either.

## Adding a harness

Append a line to the config and run `team <config> --recreate`. Anything on `$PATH`
works; the launcher prepends `~/.local/bin`, `~/.opencode/bin` and `~/bin` so
per-tool install dirs are visible to a launchd or systemd job as well.

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
