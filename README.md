# ClipboardHistory.spoon

A clipboard history manager for [Hammerspoon](https://www.hammerspoon.org/).

It polls the system pasteboard, keeps a searchable history of text, URLs,
file paths and images, and presents them in a fuzzy-searchable chooser.
History persists across restarts. Images are stored on disk; text-like
entries are kept inline.

## Features

- Fuzzy search across content, source app, date and type
- Type filters: prefix the query with `:text`, `:url`, `:file`, `:image` or `:pinned`
- Pin entries so they are never evicted
- Per-entry thumbnails for images, source-app icons otherwise
- Right-click context menu (paste, copy, pin, delete, reveal/open)
- Persistent, atomically-written history

## Installation

This Spoon is installed and updated outside of the dotfiles repo, by the
`update:spoons` mise task and the yadm bootstrap script, which clone it into
`~/.hammerspoon/Spoons/ClipboardHistory.spoon`.

To install manually:

```sh
git clone https://github.com/necrom4/ClipboardHistory.spoon \
  ~/.hammerspoon/Spoons/ClipboardHistory.spoon
```

## Usage

```lua
hs.loadSpoon("ClipboardHistory")
spoon.ClipboardHistory:bindHotkeys({
  show  = {{"cmd", "shift"}, "v"},
  clear = {{"cmd", "shift", "alt"}, "v"},
})
spoon.ClipboardHistory:start()
```

### Hotkeys

Bound via `:bindHotkeys`:

| Action  | Description                  |
| ------- | ---------------------------- |
| `show`  | Open the clipboard history   |
| `clear` | Clear all history            |

Inside the chooser:

| Key                     | Action                                            |
| ----------------------- | ------------------------------------------------- |
| `↵`                     | Paste selected entry into the previous app        |
| `⌘↵`                    | Copy to clipboard without pasting                 |
| `⌘.`                    | Pin / unpin selected entry                        |
| `⌘⌫`                    | Delete selected entry                             |
| `↑`/`↓`, `⇥`/`⇧⇥`, `⌃J`/`⌃K` | Move selection (focus stays on the search field) |

## API

- `ClipboardHistory:init()` — called automatically by `hs.loadSpoon()`
- `ClipboardHistory:start()` — start the pasteboard poller
- `ClipboardHistory:stop()` — stop the pasteboard poller
- `ClipboardHistory:bindHotkeys(mapping)` — bind `show` / `clear`
- `ClipboardHistory:show()` — open the chooser
- `ClipboardHistory:clear()` — clear all history
- `ClipboardHistory:debug()` — print internal state to the console

## Data

Runtime data lives in `data/` inside the Spoon directory
(`clipboard_history.json` and `clipboard_images/`) and is git-ignored.

## License

MIT
