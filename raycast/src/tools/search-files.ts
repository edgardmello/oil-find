import { getPreferenceValues } from "@raycast/api";
import { SearchItem, findApplication, requestOnce, startBridge } from "../bridge";

type Input = {
  /**
   * An Oil Find query. Plain words match file and folder names. Operators: `*.pdf` or `ext:pdf;docx`,
   * `kind:folder|app|doc|image|video|audio|code|archive`, `in:~/Documents` (inside a folder), `path:part/of/path`,
   * `dm:today|yesterday|week|lastweek|month|lastmonth|year|2026-11-03` (modified), `size:>10mb`, `[client]` or `content:"exact phrase"`
   * (inside files, for example `invoice [client]` or `.jpg [dog]`; quote the text, `["jane"]`, to match whole words only), `tag:Red`, `regex:^IMG_\d+`. Words are combined with AND, `|` means OR, a leading `!` excludes.
   * Use an empty string for the most recently modified files.
   */
  query: string;
  /** Also search inside files with Oil Find's content index. Defaults to true. */
  searchContents?: boolean;
  /** How many results to return, from 1 to 50. Defaults to 20. */
  limit?: number;
};

/** Searches files and folders on this Mac with the Oil Find index and returns their paths and details. */
export default async function tool(input: Input) {
  const { applicationPath } = getPreferenceValues<{ applicationPath?: string }>();
  const { executable } = findApplication(applicationPath);
  const limit = Math.min(Math.max(Math.round(input.limit ?? 20), 1), 50);
  const response = await requestOnce(executable, { type: "search", query: input.query, limit, content: false });
  if (response.error) throw new Error(`Oil Find could not run this search: ${response.error}`);

  const results = (response.items ?? []).map((item) => ({
    path: item.path,
    kind: item.isFolder ? "folder" : (item.kind ?? "file"),
    size: item.isFolder ? undefined : item.size,
    modified: new Date(item.modified * 1000).toISOString(),
  }));
  let contentMatches: { path: string; match?: string; modified: string }[] = [];
  if (input.searchContents !== false && input.query.trim()) {
    const content = await contentSearch(executable, input.query, limit);
    contentMatches = content.map((item) => ({
      path: item.path,
      match: item.snippet,
      modified: new Date(item.modified * 1000).toISOString(),
    }));
  }
  return { totalNameMatches: response.total ?? results.length, results, contentMatches };
}

/** Content matches arrive as a second answer after the filename results. */
function contentSearch(executable: string, query: string, limit: number) {
  return new Promise<SearchItem[]>((resolve) => {
    const session = startBridge(
      executable,
      (response) => {
        if (response.contentItems || !response.contentPending) {
          session.close();
          resolve((response.contentItems ?? []).slice(0, limit));
        }
      },
      () => resolve([]),
    );
    session.send(1, { type: "search", query, limit: 1, content: true });
  });
}
