# Oil Find for Raycast

Search the Oil Find index from Raycast. The extension talks to the Oil Find app itself, so it uses the same index, the same search syntax (`*.pdf`, `in:~/Projects`, `dm:week`, `size:>10mb`, `kind:image` and the rest), your fuzzy filename and sort settings, and the filters you keep in Oil Find's filter library.

## What it does

- **Content matches**: when Oil Find's content search is on, files whose text matches appear in their own section under the filename results, with the matching line. Put text in square brackets to search only inside files: `invoice [client]`, `.pdf [paid|overdue]`, or `.jpg [dog]` for photos and screenshots (Oil Find labels images with Apple's Vision framework, in English, and reads the text in them). Quote the text to match whole words only: `*.pdf ["jane"]` finds "Jane" but not "janeiro" or "janela". Brackets always search contents; otherwise the Contents preference decides.
- **Filter menu** next to the search bar: file kinds, every quick filter, folder filter and saved filter from Oil Find under the same names, and each external drive Oil Find knows. A disconnected drive is searched through its saved catalog; its results are marked Offline.
- **Details panel** (⌘I): image, text and folder previews with size, dates and kind.
- **Actions**, close to the Cling extension: Open, Show in Finder, Open With (⌘O), Quick Look (⌘Y), Copy Path, Name or File, Paste Path in the frontmost app, Open Folder in Terminal (⌘T), Open in Editor (⌘E, once an editor is set), Move to Trash (⌃X).
- **Oil Find actions**: Open Search in Oil Find (⇧⌘O) opens the panel with the same text and filter, Search in This Folder (⌘F) narrows the search with `in:`, Save as Quicklink (⇧⌘L) keeps a query and filter as a Raycast quicklink, Add to Oil Find Stash (⌘S) puts the file in the Oil Find stash, Add All Results to Stash (⌥⌘S) stashes the whole list, and Run Oil Find Script (⇧⌘R) runs the file scripts set up in Oil Find whose rules accept the file, then shows their output.
- **Oil Find Stash** command: the stashed files, with Copy All Files (⇧⌘C) to paste them anywhere at once, Run Script on All Files (⇧⌘R), Remove from Stash (⌃X), Clear Stash and Show Stash in Oil Find (⇧⌘O). Raycast lists have no multiple selection, so the stash is how you act on several files together.
- **Oil Find Index Status** command: item count, last save and size of each index, the folders Oil Find could not read and the other coverage gaps from Oil Find's "Not Covered" summary, with a shortcut to Full Disk Access.
- **Raycast AI**: `@oil-find` gives Raycast AI a Search Files tool that writes Oil Find queries (`*.pdf dm:lastweek`, `kind:image in:~/Pictures`) and gets back paths, kinds, sizes, dates and content matches.
- **Fallback command**: add Search Files with Oil Find to Raycast's fallback commands (Raycast Settings → Extensions → Fallback Commands) to search Oil Find with whatever you typed in the root search.

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

Content matches cover the startup volume only, like in Oil Find. File scripts only run if they are in Oil Find's script list, never from a path the extension sends. Folders Oil Find has no access to, such as Downloads without Full Disk Access, are not in the index.
