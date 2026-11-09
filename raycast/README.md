# Oil Find for Raycast

Search the Oil Find index from Raycast. The extension talks to the Oil Find app itself, so it uses the same index, the same search syntax (`*.pdf`, `in:~/Projects`, `dm:week`, `size:>10mb`, `kind:image` and the rest), your fuzzy filename and sort settings, and the filters you keep in Oil Find's filter library.

## What it does

- **Content matches**: when Oil Find's content search is on, files whose text matches appear in their own section under the filename results, with the matching line. Turn it off with the Contents preference.
- **Filter menu** next to the search bar: file kinds, plus every quick filter, folder filter and saved filter from Oil Find, under the same names.
- **Details panel** (⌘I): image, text and folder previews with size, dates and kind.
- **Actions**, close to the Cling extension: Open, Show in Finder, Open With (⌘O), Quick Look (⌘Y), Copy Path, Name or File, Paste Path in the frontmost app, Open Folder in Terminal (⌘T), Open in Editor (⌘E, once an editor is set), Move to Trash (⌃X).
- **Oil Find actions**: Open Search in Oil Find (⇧⌘O) opens the panel with the same text and filter, Search in This Folder (⌘F) narrows the search with `in:`, Save as Quicklink (⇧⌘L) keeps a query and filter as a Raycast quicklink, and Add to Oil Find Stash (⌘S) puts the file in the Oil Find stash.
- **Oil Find Stash** command: the stashed files, with Copy All Files (⇧⌘C) to paste them anywhere at once, Remove from Stash (⌃X), Clear Stash and Show Stash in Oil Find (⇧⌘O).

With an empty search field the list shows recent files, like the Oil Find panel.

## How it connects

The command starts the Oil Find executable with `--raycast-search` and exchanges one JSON line per request over stdin and stdout. That process loads the saved index (`~/Library/Application Support/Oil Find/index.oilfind`) once, reloads it when Oil Find saves a new one, and quits when the command closes. Content matches come from the app's content index and Spotlight through the same process, as a second line after the filename results, and stop as soon as a newer query arrives. Nothing leaves the Mac.

The stash belongs to the running app. The extension changes it with `oilfind://stash?add=…`, `remove=…`, `clear=1` or `show=1` links, opened in the background, and only reads the saved list.

The app declares the message format with `OilFindRaycastProtocol` in its `Info.plist`; `src/bridge.ts` checks it before starting. Raise both together when the messages change.

The extension uses, in order, the Oil Find App Path preference, an Oil Find that is already running, and Oil Find in `/Applications` or `~/Applications`.

## Local installation

1. Build Oil Find from this checkout with `scripts/build-app.sh` and open `build/Oil Find.app` once so it builds its index. Or install a release that includes the Raycast bridge.
2. In this folder run `npm ci`, then `npm run dev`. `ray develop` registers the extension with Raycast and rebuilds it on save. See [Raycast's guide](https://developers.raycast.com/basics/getting-started).
3. In Raycast run **Search Files with Oil Find**. If it reports an outdated Oil Find, quit the old app or set **Oil Find App Path** to the new build.

`ray build` and `ray develop` write to `~/.config/raycast/extensions`. Sandboxed tools that cannot write there fail with "operation not permitted"; run them from a normal terminal, or use `npm run build` to build into `dist/` only.

## Limits

The extension searches the startup volume index. External drives stay in the Oil Find panel; Open Search in Oil Find (⇧⌘O) takes you there. Folders Oil Find has no access to, such as Downloads without Full Disk Access, are not in the index.
