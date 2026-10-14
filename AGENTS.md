# AGENTS.md

Context for AI coding agents (and humans) working on this repo. User-facing docs are in
README.md. If `CLAUDE.local.md` or `local/` exist, they hold the maintainer's private
notes and tools. They are git-ignored, so read them but never commit them.

## Goal and constraints

A KDE Dolphin-style terminal panel for macOS Finder. Keep it **simple and
dependency-free**: zsh, `osascript` (AppleScript/JXA), an Automator Quick Action, an
`osacompile`d helper app, and an optional Swift helper compiled at install time.
Finder stays the file manager (no replacements, no Hammerspoon). Ghostty only. zsh only.
Keep the README short.

## Layout

| Path | Role |
|---|---|
| `bin/finder-terminal` | Launcher: `toggle\|open\|close\|status`. Saves Finder bounds, creates the Ghostty window, tiles, starts the watcher, restores on close. `_cleanup` is the watcher's exit hook. |
| `src/finder-terminal-watch.swift` | Preferred watcher, compiled to `bin/finder-terminal-watch` by `install.sh`. Event-driven: NSWorkspace activation, Finder AX notifications, AX window-destroyed on the panel. Raw Apple events, no NSAppleScript (saves ~30 MB). |
| `bin/finder-terminal-watch.js` | Fallback watcher (JXA, polling 50 ms / 0.5 s) when `swiftc` is missing. Must stay behaviour-compatible with the Swift one. |
| `zsh/finder-follow.zsh` | Panel-shell sync, `ff`, prompt marker. Inert unless `FINDER_FOLLOW=1`. |
| `app/finder-terminal-applet.applescript` | Source of `app/Finder Terminal.app` (built by `install.sh`). |
| `services/Toggle Terminal Panel.workflow` | Quick Action template. `install.sh` substitutes the helper app path. |
| `install.sh`, `uninstall.sh` | Install asks before touching `~/.zshrc`. Uninstall removes everything except the clone and user config. |
| `docs/*.gif` | README demos. |

Runtime state: `~/.local/state/finder-terminal/` (`log`, `watcher.pid`,
`ghostty-window`, `finder-window`, `floating`), `~/.finder-follow` (folder),
`~/.finder-follow.pid` (panel shell PID). Config: `~/.config/finder-terminal/config`
(launcher) and `.../zshrc` (panel shell).

## Hard-won facts (check before "fixing")

- **Ghostty 1.3 has an AppleScript dictionary**: `new surface configuration`
  (initial working directory, environment variables), `new window with configuration`,
  stable window ids, `exists window id`, and `perform action "toggle_window_float_on_top"`.
  `ghostty +new-window` is GTK-only and does not work on macOS.
- **Quick Actions run in Automator's XPC runner**, which can't be granted Accessibility.
  That is why the Quick Action does `open -a "Finder Terminal.app"`. The runner's
  environment is minimal, so settings come from the config file, not env vars.
- **Finder tabs are separate `Finder window` objects**. `front Finder window` is the
  active tab. `target ... as alias` fails for Recents, search results and AirDrop, and
  that failure is how they get ignored.
- **AppleScript reserved words** bit us twice: `front` and `folder` can't be variable names.
- **JXA under plain `osascript` never receives NSWorkspace notifications**, which is
  why the JXA fallback polls. Swift gets real events.
- **Stage Manager** parks every app but the active one. The panel is made
  float-on-top (Stage Manager ignores floating windows), and the watcher drops the
  float when a third app comes forward so the panel parks with Ghostty. When Finder is
  tiled full-width, the strip hides and only appears when the pointer hits x=0. Opening
  the panel briefly parks Finder (~0.6 s) because Ghostty's new window activates Ghostty.
  This is known and accepted for now.
- **Prompt marker** uses `%(9V...)` (element 9 non-empty), not `%(9v...)`.
- **SIGALRM nudge**: the watcher signals the panel shell so it `cd`s at once. It only
  signals a `zsh` whose ancestor within 3 levels is Ghostty, because Ghostty starts
  shells via `login(1)` and a stale PID must never be hit.
- **Loop guards**: the shell reacts only to *changes* of `~/.finder-follow`, ignores it
  for 1.5 s after its own push, and doesn't push a `cd` it made for Finder.

## Testing

No automated suite. Before claiming a change works, exercise it on a real Mac:

- Both sync directions, Finder tab switching, special locations (Recents, AirDrop,
  Trash), and paths with spaces and unicode.
- Toggle on/off restores Finder's bounds. Closing the panel window by hand restores too.
- With and without Stage Manager (System Settings → Desktop & Dock).
- The Quick Action path, not only `bin/finder-terminal` (permissions differ).
- Shell behaviour can be driven headlessly with `expect` against
  `FINDER_FOLLOW=1 zsh -f -i` sourcing the snippet.
- Watcher cost: `ps -o pcpu,rss -p $(cat ~/.local/state/finder-terminal/watcher.pid)`.
  The Swift watcher is ~14 MB and <0.1 % CPU idle.

## Ideas not built

1. Keep the panel docked when the Finder window moves or resizes.
2. A Finder Sync extension so the toggle also appears when right-clicking empty space.
3. Shorten the ~0.6 s Stage Manager flash when the panel opens.
4. A demo GIF without Stage Manager.
