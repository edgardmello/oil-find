# Explicit content search

This personal build keeps filename and content search under your control:

| Query | Searches |
| --- | --- |
| `client` | File names |
| `[client]` | File contents only |
| `["payment received"]` | That contiguous phrase in the contents, in the same order |
| `content:client` | File contents only; equivalent to `[client]` |
| `content:"payment received"` | A phrase in the contents |
| `invoice [client]` | A filename containing invoice AND contents containing client |
| `*.pdf [client]` or `ext:pdf [client]` | Contents of PDF files |
| `kind:image ["payment received"]` | Text recognized inside images |
| `[invoice|receipt]` | Either content alternative |
| `[client] [!paid]` | Contents containing client and excluding paid |

Content comparisons ignore capitalization and accents and match contiguous text. Short words such as `[UI]` also work. Quotes inside brackets preserve a literal `|`: `["a|b"]`. Use `|` inside brackets to express content alternatives. Content exclusions accompany a positive content term; an exclusion by itself does not enumerate every file. An unfinished bracket or empty `content:` expression never falls back to filename matches or recent files.

The normal filename engine, AI topic results and content results are not mixed for an explicit content query. Terms outside brackets remain filename/scope/type constraints for that content query. A filename containing a content term is insufficient: the extracted body must actually contain it.

## Settings and supported files

Enable **File Content Search** in Settings. The code/text switch covers plain text, code, Markdown and configuration files. The documents switch covers PDF, Office XML, rich text and images. Switching content search off leaves ordinary filename search available.

Text recognition in images uses the system Vision framework on this Mac; images are not uploaded. OCR recognizes printed text and is not an object search such as finding every photo of a dog. Recognition accuracy depends on legibility and image quality. Images are decoded into thumbnails up to 2048 pixels on the longest side to bound memory use.

Existing extraction limits still apply: plain text files up to 2 MiB, documents/images up to 24 MiB, and a stored text prefix capped at roughly 128K characters. Image formats include PNG, JPEG, HEIC, TIFF, BMP and WebP where supported by macOS. Files must belong to an enabled, online, indexed source and pass the current filters and exclusion settings.

## Execution

The filename index resolves structure and scope, while the optional extension resolves explicit content terms. Text is served from the local SQLite content index or extracted on demand. Spotlight contributes candidates, whose extracted text is checked before they become results. File reads and OCR run outside the filename-index read lock. A Spotlight content query gets a bounded 0.5-second gathering window and supports cancellation; an incomplete result is not cached as a complete answer.

Background extraction yields while the search panel or primary index is busy. On-demand extraction has a bounded candidate/time budget; files not processed immediately become searchable as background indexing finishes. OCR of a single image can outlast that per-search budget, since the budget is checked between files. Scanned PDFs without an existing text layer are not covered by image OCR.

## Validation for this change

- 28 focused tests passed, covering parser intent, literal phrases, quoted alternatives, short terms, name/content separation, OCR, and the search interface.
- A real-index PDF search passed after adopting the explicit `[term]` syntax. The short-alternative database regression also passed after its final query-plan adjustment.
- The broader core/content run exercised 137 tests. Its existing coverage assertion (`M17Tests.testCoverageCountsSamplesPersistenceCompactionAndIncrementalExclusion`, `missing` versus `pending`) was reproduced in an untouched HEAD copy. The legacy PDF test was updated to explicit content syntax and passed independently afterward.
- The two public/private module-boundary checks passed.
- Debug and release application bundles were built and signature-verified.
- A light-appearance debug snapshot showed one matching body and excluded a decoy containing the phrase only in its filename. A dark-appearance snapshot was also captured, but its deferred table row did not render in the static image. Temporary sample files and their content-cache records were removed after verification.

## Live index refresh regression

Filesystem notifications previously restarted explicit content queries before extraction completed, leaving the panel empty during ongoing indexing. Such notifications now let the pending query finish while its source identities remain unchanged. Content matches are revalidated against each entry's path, size, modification time and structural predicates, then stamped with the current source version before merging. Source replacement and disconnection still invalidate work; user edits still cancel the old query.

Validation: 25 focused parser, content, editing, source and supplementary-interface tests passed, including PDF wildcard/body-only matching and completion during repeated index notifications. Two module-boundary checks passed. The actual application displayed 263 results for `*.pdf [fernanda]` across the active local sources. Debug and release bundles built successfully; the release signature was verified.
