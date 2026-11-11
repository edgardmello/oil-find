# Oil Find for Raycast

Search the Oil Find index from Raycast. The extension talks to the Oil Find app itself, so it uses the same index, the same search syntax (`*.pdf`, `in:~/Projects`, `dm:week`, `size:>10mb`, `kind:image` and the rest), your fuzzy filename and sort settings, and the filters you keep in Oil Find's filter library.

## What it does

- **Filter menu** next to the search bar: file kinds, plus every quick filter, folder filter and saved filter from Oil Find, under the same names.
- **Details panel** (⌘I): image, text and folder previews with size, dates and kind.
- **Actions**, close to the Cling extension: Open, Show in Finder, Open With (⌘O), Quick Look (⌘Y), Copy Path, Name or File, Paste Path in the frontmost app, Open Folder in Terminal (⌘T), Open in Editor (⌘E, once an editor is set), Move to Trash (⌃X).
- **Oil Find actions**: Open Search in Oil Find (⇧⌘O) opens the panel with the same text and filter, Search in This Folder (⌘F) narrows the search with `in:`, and Save as Quicklink (⇧⌘L) keeps a query and filter as a Raycast quicklink.

With an empty search field the list shows recent files, like the Oil Find panel.

## How it connects

The command starts the Oil Find executable with `--raycast-search` and exchanges one JSON line per request over stdin and stdout. That process loads the saved index (`~/Library/Application Support/Oil Find/index.oilfind`) once, reloads it when Oil Find saves a new one, and quits when the command closes. Nothing leaves the Mac.

The app declares the message format with `OilFindRaycastProtocol` in its `Info.plist`; `src/bridge.ts` checks it before starting. Raise both together when the messages change.

The extension uses, in order, the Oil Find App Path preference, an Oil Find that is already running, and Oil Find in `/Applications` or `~/Applications`.

## Local installation

The app build does not install the extension. Run `./build.sh raycast` from the repository root to install the extension compatible with this checkout. It archives the previous installed extension under the ignored `.local-archive/raycast/` directory before replacing it.

1. Build Oil Find from this checkout with `scripts/build-app.sh` and open `build/Oil Find.app` once so it builds its index. Or install a release that includes the Raycast bridge.
2. In this folder run `npm ci`, then `npm run dev`. `ray develop` registers the extension with Raycast and rebuilds it on save. See [Raycast's guide](https://developers.raycast.com/basics/getting-started).
3. In Raycast run **Search Files with Oil Find**. If it reports an outdated Oil Find, quit the old app or set **Oil Find App Path** to the new build.

`ray build` without `-o` and `ray develop` write to `~/.config/raycast/extensions`. Sandboxed tools that cannot write there fail with "operation not permitted"; run them from a normal terminal, or use `npm run build` (`ray build -e dist -o dist`) to build into `dist/` only.

## Limits

The extension searches filenames and paths in the startup volume index. Content search and external drives stay in the Oil Find panel; Open Search in Oil Find (⇧⌘O) takes you there. Folders Oil Find has no access to, such as Downloads without Full Disk Access, are not in the index.

If an older temporary build installed a different bridge protocol, rebuild the extension with `./build.sh raycast`. The extension and app must declare the same protocol version.
