# Shorty

`Shorty` is a small macOS utility that binds global shortcuts to specific windows, not just apps.

Example: `cmd+option+1` can always bring your "project-a" VS Code window to the front, even if another VS Code window is focused or the target window is minimized.

## What It Does

- Registers global shortcuts with native macOS APIs.
- Finds a matching window by bundle ID, app identity, executable path, and optional window metadata matchers.
- Unminimizes the window if needed and brings it to the front.
- Records text/rich-text clipboard history (last 200 items, persisted to `~/Library/Application Support/Shorty/ClipboardHistory.json`).
- Opens a searchable clipboard history + snippets picker with `cmd+shift+v`, or a snippets-only picker with `cmd+shift+b`, and pastes the selection into the previously focused app.
- Pastes YAML-defined snippets grouped into folders.
- Opens a text command palette with `option+space` for epoch timestamp conversion, byte-unit conversion, and current time in several time zones.
- Shows a lightweight window switcher with `cmd+tab`, plus a current-app window switcher with `cmd+tilde/backquote`.
- Moves and resizes the focused window with Rectangle-style hardcoded shortcuts.
- Reloads its YAML config file automatically when you save changes.
- Runs as a menu bar utility showing status, config path, and loaded shortcuts, with `Show Windows`, `Reload Config`, `Reveal Config`, `Open Accessibility Settings`, and `Quit`.
- CLI modes: `--list-windows [--verbose]`, `--validate-config`, `--config PATH`, `--help`.

## Requirements

- macOS 13+
- Swift 6 / Xcode command line tools
- Accessibility permission for the built `Shorty` binary

## Build

```bash
./build.sh
```

If the project directory moved and SwiftPM has stale module-cache paths, `build.sh` cleans local SwiftPM build artifacts and retries once.

## Build App

```bash
./build-app.sh
```

That creates:

```text
./dist/Shorty.app
```

Run it with:

```bash
open ./dist/Shorty.app
```

After code changes, run `./build-app.sh` again, quit the old Shorty instance from the menu bar, and reopen `./dist/Shorty.app`. macOS permissions are tied to the app or binary you launch, so testing the `.app` needs the rebuilt `.app`, not the raw `.build` binary.

When launched as an app, Shorty uses its default config path:

```text
~/config/shorty.yaml
```

Create that directory and put your config there before launching from Finder:

```bash
mkdir -p "$HOME/config"
cp ./config.yaml "$HOME/config/shorty.yaml"
```

## Run

```bash
./run.sh
```

`run.sh` launches the built binary with the repo-local `./config.yaml`.

If you want to run a different config directly:

```bash
./.build/arm64-apple-macosx/debug/Shorty --config ./Config.sample.yaml
```

If the binary does not exist yet, `run.sh` will build it once. After code changes, rebuild manually with `./build.sh` before restarting.

To inspect current windows and discover match values:

```bash
./.build/arm64-apple-macosx/debug/Shorty --list-windows
./.build/arm64-apple-macosx/debug/Shorty --list-windows --verbose
```

Plain mode prints one labeled block per accessible window:

```text
Bundle ID: com.example.App
Window title: Project
Best match value: file:///Users/example/project/file.txt
```

Verbose mode also prints:

- `appWindowIndex`
- `document`
- `url`
- `identifier`
- `executablePath`
- `role` / `subrole`
- `position` / `size`
- `minimized`

If you omit `--config`, Shorty looks for:

```text
~/config/shorty.yaml
```

The first time you run it, macOS should prompt for Accessibility access. Shorty's status menu also includes a direct link to the relevant privacy pane. If the app appears in the list, enable its toggle; if it does not, add the built `Shorty` binary manually in:

`System Settings > Privacy & Security > Accessibility`

For the `.app` bundle, add `dist/Shorty.app` to Accessibility instead of the raw binary.

## Validate Config

```bash
./.build/arm64-apple-macosx/debug/Shorty --validate-config --config ./Config.sample.yaml
```

## Finding Bundle IDs

Use Shorty itself:

```bash
./.build/arm64-apple-macosx/debug/Shorty --list-windows
```

If you already know the app name, these macOS commands also work:

```bash
osascript -e 'id of app "Visual Studio Code"'
mdls -name kMDItemCFBundleIdentifier -r /Applications/Visual\ Studio\ Code.app
```

## Config Format

The default config file is YAML:

```yaml
shortcuts:
  project-a:
    hotkey: cmd+option+1
    bundle-id: com.microsoft.VSCode
    title-regex: project-a
```

Each key under `shortcuts` is the shortcut id shown in logs. `Config.sample.yaml` includes examples for every supported matcher type.

The repo-local `config.yaml` is your personal runtime config and is ignored by git.

### Snippet Fields

Snippets live in the same YAML file and use one level of grouping:

```yaml
snippets:
  Work:
    Greeting: Hello from Shorty.
    Rich Example: Plain fallback text
  Personal:
    Address: 123 Example St
```

The group key becomes a picker folder. The snippet key becomes the item title. The value is pasted as plain text. Groups and snippets appear in the same order as the config.

### Clipboard History

Shorty polls the pasteboard every 0.75s and stores new items, newest first, deduplicated by content. It keeps plain text plus RTF, RTFD, HTML, web archive, and other rich-text representations. Images, files, URLs, audio, and video representations are not stored. History holds up to 200 items and survives restarts.

Shorty uses these hardcoded clipboard shortcuts:

- `cmd+shift+v`: open the combined clipboard history and snippets picker.
- `cmd+shift+b`: open the snippets-only picker.

The picker is a floating panel with a search field. History shows the 20 most recent items directly, then up to 180 more in folders of 20 (`21 - 40`, …). Snippet groups appear as folders. Item titles use the first line, and multi-line items show a `+N` count of additional lines.

Picker keys:

- Type to filter history and snippets (case- and diacritic-insensitive; matches history text, snippet group, title, and content). Matching items inside folders are shown at the top level while searching.
- `up` / `down`: move selection.
- `right`: open the selected folder. `left`, `escape`, or `delete` with an empty search: leave the folder.
- `escape` at the top level: close the picker.
- `return`: paste the selected item into the app that was focused before the picker opened.
- `cmd+return`: paste the plain-text version without formatting.
- `shift+return`: trim every line, discard empty lines, join the remaining lines with no separator, save that transformed text as the newest history item, and paste it. If both `cmd` and `shift` are held, the `shift` behavior is used.

### Command Palette

`option+space` opens a floating command palette. As you type, every matching command shows a live result; partially typed commands show the remaining words as placeholders. `return` copies the first complete result to the clipboard and closes the palette. `escape` closes it.

Commands:

| Input | Result |
| --- | --- |
| 10-digit number, e.g. `1700000000` | Epoch seconds as UTC and San Francisco time, plus relative time (`2d 3h 4m 5s ago`) |
| 14-digit number | Epoch milliseconds, same output |
| `<amount> <unit>`, unit `b`/`bytes`/`kb`/`mb`/`gb`/`tb`, e.g. `1.5 gb` | The value in every other unit (1024-based) |
| `utc time`, `et time`, `cet time`, `turkey time`, `dubai time`, `korea time`, `japan time` | Current time in that zone |

Inside the palette, `cmd+v` pastes the system clipboard, `cmd+shift+v` / `cmd+shift+b` open the clipboard / snippets picker and insert the chosen item's plain text at the cursor, `cmd+c` copies the selection, and `cmd+a` selects all.

### Window Switcher

Shorty uses these hardcoded window switcher shortcuts:

- `cmd+tab`: show all windows in last-use order.
- `cmd+tilde/backquote`: show windows from the current app in last-use order.

Keep holding Command and press Tab or tilde/backquote again to move down the list. Press Shift-Tab to move up. Release Command to activate the selected window. Press Escape to cancel.

The switcher uses a cached, low-detail Accessibility snapshot: app name, bundle ID, process ID, AX window reference, and title. It does not use the slower verbose metadata path from `--list-windows --verbose`.

If a window matches a configured shortcut, the switcher shows that shortcut id before the window title. If multiple windows match the same shortcut, they all show the shortcut id, even when the shortcut uses `window-index` for activation. Shortcuts that depend on document, URL, or identifier metadata are labeled after Shorty's background metadata cache has refreshed.

### Window Movement

Shorty uses these hardcoded window movement shortcuts:

- `ctrl+option+left`: move the focused window to the left half of the current monitor. If already in the left half, move to the right half of the monitor to the left. From the leftmost monitor, wrap to the right half of the rightmost monitor.
- `ctrl+option+right`: move the focused window to the right half of the current monitor. If already in the right half, move to the left half of the monitor to the right. From the rightmost monitor, wrap to the left half of the leftmost monitor.
- `ctrl+option+cmd+up`: maximize the focused window to the current monitor's usable area.
- `ctrl+option+cmd+left`: move the focused window to the monitor to the left, preserving proportional position and size. Wraps from leftmost to rightmost.
- `ctrl+option+cmd+right`: move the focused window to the monitor to the right, preserving proportional position and size. Wraps from rightmost to leftmost.

Window movement uses each monitor's visible frame, so windows avoid the menu bar and Dock. Some full-screen, minimized, or non-resizable windows may refuse Accessibility resize commands.

All hardcoded hotkeys above (clipboard, snippets, command palette, window switcher, window movement) are reserved and cannot be reused by window shortcuts.

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

## Notes

- VS Code usually exposes enough title text for project-level matching.
- Cursor, Zed, and other editors may expose a more useful `document` or `url` than `title`; use `--list-windows --verbose` to inspect that first.
- If you run multiple app installs with the same bundle ID, match the install directly with `executable-path-prefix` and leave out window-title matchers.
- If a target app does not expose useful Accessibility window metadata, try combining `bundle-id` with a broader `title-regex`.
