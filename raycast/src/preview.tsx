import { Color, List } from "@raycast/api";
import { closeSync, openSync, readSync, readdirSync, statSync } from "node:fs";
import { basename, extname } from "node:path";
import { SearchItem } from "./bridge";
import { displayPath } from "./paths";

const imageExtensions = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp", ".tiff", ".svg", ".ico"]);
const textExtensions = new Set([
  ".txt", ".md", ".markdown", ".json", ".yaml", ".yml", ".toml", ".ini", ".conf", ".cfg", ".plist", ".xml", ".csv",
  ".log", ".env", ".sh", ".zsh", ".bash", ".py", ".rb", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".swift",
  ".c", ".h", ".m", ".mm", ".cpp", ".hpp", ".rs", ".go", ".java", ".kt", ".cs", ".php", ".sql", ".html", ".css",
  ".scss", ".vue", ".svelte", ".lua", ".r", ".tex", ".gitignore",
]);
const previewBytes = 8 * 1024;

const kindNames: Record<string, string> = {
  folder: "Folder", app: "App", doc: "Document", image: "Image", video: "Video", audio: "Audio", code: "Code",
  archive: "Archive",
};

export function kindName(item: SearchItem) {
  return item.isFolder ? "Folder" : (item.kind && kindNames[item.kind]) || "File";
}

export function formatSize(bytes: number) {
  if (bytes < 1000) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

export function formatDate(seconds: number) {
  return new Date(seconds * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function fence(text: string) {
  const longest = Math.max(2, ...(text.match(/`+/g) ?? []).map((run) => run.length));
  return "`".repeat(longest + 1);
}

function markdown(item: SearchItem) {
  const name = basename(item.path);
  const extension = extname(item.path).toLowerCase();
  if (item.isFolder) {
    try {
      const entries = readdirSync(item.path, { withFileTypes: true })
        .filter((entry) => !entry.name.startsWith("."))
        .sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
      const lines = entries.slice(0, 40).map((entry) => `- ${entry.isDirectory() ? "📁" : "📄"} ${entry.name}`);
      const more = entries.length > 40 ? `\n- … ${entries.length - 40} more` : "";
      return `### ${name}\n\n${lines.length ? lines.join("\n") + more : "*Empty folder*"}`;
    } catch {
      return `### ${name}\n\n*Oil Find can see this folder, but Raycast cannot read it.*`;
    }
  }
  if (item.kind === "image" || imageExtensions.has(extension)) {
    return `![${name}](${encodeURI("file://" + item.path)})`;
  }
  if (item.kind === "code" || textExtensions.has(extension) || (!extension && item.size < previewBytes)) {
    try {
      const file = openSync(item.path, "r");
      const buffer = Buffer.alloc(Math.min(previewBytes, item.size));
      const read = readSync(file, buffer, 0, buffer.length, 0);
      closeSync(file);
      const text = buffer.subarray(0, read).toString("utf8");
      if (!text.includes("\0")) {
        const truncated = item.size > previewBytes ? "\n…" : "";
        const marker = fence(text);
        return `${marker}${extension.slice(1)}\n${text}${truncated}\n${marker}`;
      }
    } catch {
      return `### ${name}\n\n*Raycast cannot read this file.*`;
    }
  }
  return `### ${name}\n\n*Press ⌘Y for Quick Look.*`;
}

function created(path: string) {
  try {
    return statSync(path).birthtime;
  } catch {
    return undefined;
  }
}

export function ItemDetail({ item }: { item: SearchItem }) {
  const birth = created(item.path);
  return (
    <List.Item.Detail
      markdown={(item.snippet ? `> ${item.snippet.replace(/\n/g, " ")}\n\n` : "") + markdown(item)}
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.Label title="Name" text={basename(item.path)} />
          <List.Item.Detail.Metadata.Label title="Where" text={displayPath(item.path, true)} />
          <List.Item.Detail.Metadata.TagList title="Kind">
            <List.Item.Detail.Metadata.TagList.Item
              text={kindName(item)}
              color={item.isFolder ? Color.Blue : Color.SecondaryText}
            />
          </List.Item.Detail.Metadata.TagList>
          <List.Item.Detail.Metadata.Separator />
          {!item.isFolder && <List.Item.Detail.Metadata.Label title="Size" text={formatSize(item.size)} />}
          <List.Item.Detail.Metadata.Label title="Modified" text={formatDate(item.modified)} />
          {birth && <List.Item.Detail.Metadata.Label title="Created" text={formatDate(birth.getTime() / 1000)} />}
        </List.Item.Detail.Metadata>
      }
    />
  );
}
