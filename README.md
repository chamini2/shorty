# Shorty

`Shorty` is a small macOS menu bar utility. It does four things:

| # | Feature | Hotkey |
| --- | --- | --- |
| 1 | [Global app shortcuts](#1-global-app-shortcuts): bind a hotkey to a specific window, not just an app | configured in YAML |
| 2 | [Window switcher](#2-window-switcher): switch between windows, not apps | `cmd+tab`, `cmd+tilde/backquote` |
| 3 | [Clipboard manager + snippets](#3-clipboard-manager--snippets): searchable clipboard history and YAML snippets | `cmd+shift+v`, `cmd+shift+b` |
| 4 | [Command box](#4-command-box): epoch timestamps, byte units, time zones | `option+space` |

Every built-in hotkey can be rebound or switched off in [Hotkeys](#hotkeys). A bound key cannot be reused by an app shortcut.

## 1. Global App Shortcuts

Bind a global hotkey to a specific window. Example: `cmd+option+1` always brings your "project-a" VS Code window to the front, even if another VS Code window is focused or the target is minimized.

Shorty finds the window by bundle ID, app name, executable path, and optional window metadata (title, document, URL, Accessibility identifier), unminimizes it if needed, and brings it to the front.

Shortcuts live in the YAML config:

```yaml
shortcuts:
  project-a:
    hotkey: cmd+option+1
    bundle-id: com.microsoft.VSCode
    title-regex: project-a
```

Each key under `shortcuts` is the shortcut id shown in logs and in the window switcher. `Config.sample.yaml` has an example for every matcher.

### Shortcut Fields

- `hotkey`: Global shortcut like `cmd+option+1`, `ctrl+shift+f3`, `cmd+alt+space`.
- `bundle-id`: Exact macOS bundle identifier, e.g. `com.microsoft.VSCode`.
- `app-name-regex`: Optional regex for the app display name.
- `executable-path-prefix`: Optional plain prefix for the app executable path. Use a normal path like `/Applications/Cursor.app/`, with no `^` or regex escaping.
- `title-regex`: Optional regex applied to the window title.
- `title-contains`: Optional case-insensitive plain substring match on the window title.
- `document-regex`: Optional regex applied to the window document path when the app exposes one.
- `url-regex`: Optional regex applied to the window URL when the app exposes one.
- `identifier-regex`: Optional regex applied to the Accessibility identifier when the app exposes one.
- `window-index`: Optional zero-based index if multiple windows match. Defaults to `0`.

At least one matcher must be set: `bundle-id`, `app-name-regex`, `executable-path-prefix`, `title-regex`, `title-contains`, `document-regex`, `url-regex`, or `identifier-regex`.

### Finding Match Values

List current windows and their match values:

```bash
./.build/arm64-apple-macosx/debug/Shorty --list-windows
./.build/arm64-apple-macosx/debug/Shorty --list-windows --verbose
```

Plain mode prints one block per accessible window:

```text
Bundle ID: com.example.App
Window title: Project
Best match value: file:///Users/example/project/file.txt
```

Verbose mode also prints `appWindowIndex`, `document`, `url`, `identifier`, `executablePath`, `role` / `subrole`, `position` / `size`, and `minimized`. The menu bar `Show Windows` item shows the same list.

If you already know the app name:

```bash
osascript -e 'id of app "Visual Studio Code"'
mdls -name kMDItemCFBundleIdentifier -r /Applications/Visual\ Studio\ Code.app
```

### Tips

- VS Code usually exposes enough title text for project-level matching.
- Cursor, Zed, and other editors may expose a more useful `document` or `url` than `title`; check with `--list-windows --verbose`.
- If you run multiple installs with the same bundle ID, match the install with `executable-path-prefix` and leave out window-title matchers.
- If an app does not expose useful window metadata, combine `bundle-id` with a broader `title-regex`.

## 2. Window Switcher

| Hotkey | Action |
| --- | --- |
| `cmd+tab` | Show all windows in last-use order |
| `cmd+tilde/backquote` | Show windows of the current app in last-use order |

Keep holding Command and press Tab or tilde/backquote again to move down. Shift-Tab moves up. Release Command to activate the selected window. Escape cancels.

If a window matches a configured app shortcut, the switcher shows that shortcut id before the title. Shortcuts that depend on document, URL, or identifier metadata are labeled once Shorty's background metadata cache has refreshed.

### Window Movement

Rectangle-style hotkeys for the focused window:

| Hotkey | Action |
| --- | --- |
| `ctrl+option+left` | Left half of the current monitor. If already there, right half of the monitor to the left (wraps). |
| `ctrl+option+right` | Right half of the current monitor. If already there, left half of the monitor to the right (wraps). |
| `ctrl+option+cmd+up` | Maximize to the current monitor |
| `ctrl+option+cmd+left` | Move to the monitor on the left, keeping proportional position and size (wraps) |
| `ctrl+option+cmd+right` | Move to the monitor on the right, keeping proportional position and size (wraps) |

Windows stay clear of the menu bar and Dock. Some full-screen, minimized, or non-resizable windows refuse resizing.

## 3. Clipboard Manager + Snippets

| Hotkey | Action |
| --- | --- |
| `cmd+shift+v` | Open clipboard history and snippets |
| `cmd+shift+b` | Open snippets only |

The picker is a floating panel with a search box. Choosing an item pastes it into the app you were in.

| Key | Action |
| --- | --- |
| type | Filter history and snippets |
| `up` / `down` | Move selection |
| `right` | Open folder |
| `left` / `escape` | Leave folder; `escape` at the top closes the picker |
| `return` | Paste |
| `cmd+return` | Paste as plain text (no formatting) |
| `shift+return` | Trim each line, drop empty lines, join with no separator, save as a new history item, and paste |

### Clipboard History

- Keeps the last 200 items, newest first, without duplicates.
- Keeps plain text and rich text (RTF, HTML, etc.). Images, files, and URLs are not stored.
- Persists across restarts in `~/Library/Application Support/Shorty/ClipboardHistory.json`.
- The picker shows the 20 most recent items directly; older ones are in folders of 20 (`21 - 40`, …).

### Snippets

Snippets live in the YAML config, grouped one level deep:

```yaml
snippets:
  Work:
    Greeting: Hello from Shorty.
  Personal:
    Address: 123 Example St
```

Each group is a folder in the picker, each key is an item title, and the value is pasted as plain text. Order follows the config.

Snippets sit above the clipboard history in the picker. The picker opens on the
newest history entry, so snippets are one `up` away and never in the way.

### Picker Keys

| Key | Action |
| --- | --- |
| `return` | Paste the entry, keeping rich text |
| `cmd+return` | Copy to the clipboard without pasting |
| `option+return` | Paste as plain text |
| `shift+return` | Paste with blank lines dropped and lines joined |
| `cmd+v` / `cmd+c` / `cmd+x` / `cmd+a` | Edit the search field |

Modifiers also work on click, and `shift` wins over `cmd`, which wins over
`option`.

## 4. Command Box

`option+space` opens a command box. Type a command and see the result live. `return` copies the result to the clipboard; `escape` closes.

| Type | Result |
| --- | --- |
| `1700000000` (10 digits) | Epoch seconds as UTC and San Francisco time, plus "2d 3h ago" |
| `17000000000000` (14 digits) | Epoch milliseconds, same output |
| `1.5 gb` (units `b`, `bytes`, `kb`, `mb`, `gb`, `tb`) | The size in every other unit (1024-based) |
| `utc time`, `et time`, `cet time`, `turkey time`, `dubai time`, `korea time`, `japan time` | Current time in that zone |

Inside the command box, `cmd+shift+v` / `cmd+shift+b` open the clipboard / snippets picker and insert the chosen text at the cursor.

To turn the command box off, set `command-box: off` under `hotkeys`. Shorty then leaves `option+space` to other apps, and an app shortcut may use it.

## Hotkeys

Every built-in key lives in an optional top-level `hotkeys` section. Set a key to rebind it, or to `off` to unbind it:

```yaml
hotkeys:
  clipboard-menu: cmd+shift+v
  snippets-menu: cmd+shift+b
  command-box: off
  window-switcher:
    all-windows: cmd+tab
    current-app: cmd+grave
  window-movement:
    left-half: ctrl+option+left
    right-half: ctrl+option+right
    maximize: ctrl+option+cmd+up
    left-monitor: ctrl+option+cmd+left
    right-monitor: ctrl+option+cmd+right
```

- A binding you leave out keeps its default key. Only an explicit `off` unbinds one, so an upgrade never silently removes a feature. `false`, `none` and an empty value also work.
- `window-switcher` and `window-movement` take their own keys, or `off` to unbind the whole group in one line.
- No key, no feature: an unbound action is not registered at all, and its background work never starts. With both `window-switcher` keys off, the global event tap and the window index stay down. With `clipboard-menu`, `snippets-menu`, and `command-box` all off, Shorty stops recording clipboard history, since nothing can show it.
- Switcher keys need a modifier, because the switcher cycles while you hold it.
- A built-in binding and an app shortcut cannot share a key. Unbind the built-in to hand the key over.

Bindings apply on config reload, so no restart is needed.

## Setup

### Requirements

- macOS 13+
- Swift 6 / Xcode command line tools
- Accessibility permission

### Build and Run the App

```bash
./build-app.sh
open ./dist/Shorty.app
```

The app reads its config from `~/.shorty/config.yaml`:

```bash
mkdir -p "$HOME/.shorty"
cp ./Config.sample.yaml "$HOME/.shorty/config.yaml"
```

If `~/.shorty/config.yaml` is missing, Shorty falls back to the old `~/config/shorty.yaml` path. Move that file to `~/.shorty/config.yaml` when you want the hidden folder.

Shorty reloads the config automatically when you save it.

After code changes, run `./build-app.sh` again, quit Shorty from the menu bar, and reopen `./dist/Shorty.app`.

### Accessibility Permission

On first launch macOS should prompt for Accessibility access. The menu bar `Open Accessibility Settings` item links to the pane. If Shorty is not listed, add it manually in `System Settings > Privacy & Security > Accessibility` (add `dist/Shorty.app` for the app, or the raw binary when running from `.build`).

### Signing

`build-app.sh` signs the app ad-hoc by default. An ad-hoc signature changes with
every build, so macOS treats each reinstall as a different app and drops its
Accessibility approval. Creating one local signing identity keeps the signature
stable and the approval with it.

Make the identity once, in Keychain Access:

1. `Keychain Access > Certificate Assistant > Create a Certificate…`
2. Name `Shorty Local Signing`, Identity Type `Self Signed Root`, Certificate
   Type `Code Signing`, then create it.

`build-app.sh` picks it up automatically on the next build. Use another name by
setting `SHORTY_SIGN_IDENTITY`. With no identity present the build still works,
signs ad-hoc, and warns that the permission will reset.

A self-signed certificate is normally untrusted, so `security find-identity -p
codesigning` lists nothing even when signing works. The build therefore tries
the identity and falls back only if `codesign` refuses it.

Approve Accessibility once more after the first signed build: the signature
changes from ad-hoc to the new identity, which macOS sees as a new app. From
then on the approval survives reinstalls.

### Development Build

```bash
./build.sh   # build
./run.sh     # run with repo-local ./config.yaml (gitignored), builds once if missing
```

If the project directory moved and SwiftPM has stale module-cache paths, `build.sh` cleans and retries once.

### Command Line

```text
Shorty [--config PATH]                       Run (default config: ~/.shorty/config.yaml)
Shorty --validate-config [--config PATH]     Validate config and exit
Shorty --list-windows [--verbose]            Print accessible windows and match values
Shorty --help
```

### Menu Bar

The menu shows status, config path, and loaded shortcuts, plus `Show Windows`, `Reload Config`, `Reveal Config`, `Open Accessibility Settings`, and `Quit`.
