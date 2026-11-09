import {
  Action,
  ActionPanel,
  Application,
  Icon,
  Image,
  LaunchProps,
  List,
  environment,
  getPreferenceValues,
  open,
  openExtensionPreferences,
  showToast,
  Toast,
} from "@raycast/api";
import { basename, dirname } from "node:path";
import { useEffect, useRef, useState } from "react";
import { BridgeResponse, SearchFilter, SearchItem, findApplication, startBridge } from "./bridge";
import { displayPath, folderQuery } from "./paths";
import { ItemDetail, formatDate, formatSize } from "./preview";

interface Preferences {
  applicationPath?: string;
  terminalApp?: Application;
  editorApp?: Application;
  showDetail: boolean;
}

interface LaunchContext {
  query?: string;
  filter?: string;
}

const allFilter = "all";
const resultLimit = 100;

const filterIcons: Record<string, Image.ImageLike> = {
  folder: Icon.Folder,
  app: Icon.AppWindowGrid3x3,
  photo: Icon.Image,
  image: Icon.Image,
  film: Icon.FilmStrip,
  video: Icon.FilmStrip,
  waveform: Icon.Music,
  audio: Icon.Music,
  "doc.text": Icon.Document,
  document: Icon.Document,
  archivebox: Icon.Box,
  archive: Icon.Box,
  "chevron.left.forwardslash.chevron.right": Icon.Code,
  code: Icon.Code,
  gearshape: Icon.Gear,
  "doc.richtext": Icon.BlankDocument,
  hammer: Icon.Hammer,
  house: Icon.House,
  icloud: Icon.Cloud,
  externaldrive: Icon.HardDrive,
  desktopcomputer: Icon.Monitor,
};

function filterIcon(filter: SearchFilter) {
  const key = filter.section === "kind" ? filter.id.slice("kind:".length) : filter.symbol;
  return (key && filterIcons[key]) || Icon.Filter;
}

const sections: { id: SearchFilter["section"]; title: string }[] = [
  { id: "kind", title: "Kinds" },
  { id: "quick", title: "Quick Filters" },
  { id: "folder", title: "Folders" },
  { id: "saved", title: "Saved Filters" },
];

const errorMessages: Record<string, string> = {
  indexUnavailable: "Open Oil Find and let it finish building its index, then retry.",
  filterUnavailable: "This filter no longer exists in Oil Find. Choose another one.",
};

function describeError(error: string) {
  if (errorMessages[error]) return errorMessages[error];
  if (error.startsWith("invalidQuery:")) return "Check the search syntax. Open the search in Oil Find to see the full hint.";
  return error;
}

/** The link Oil Find understands. Saved quick filters carry their own search text, like in the app. */
function oilFindURL(query: string, filter: SearchFilter | undefined) {
  const parameters = new URLSearchParams();
  parameters.set("q", filter?.query ? `${filter.query} ${query}`.trim() : query);
  if (filter?.section === "kind") parameters.set("filter", filter.id.slice("kind:".length));
  else if (filter) parameters.set("library", filter.id.slice("library:".length));
  return "oilfind://search?" + parameters.toString().replace(/\+/g, "%20");
}

function quicklink(query: string, filter: string) {
  const context = encodeURIComponent(JSON.stringify({ query, filter }));
  return `raycast://extensions/edgardmello/${environment.extensionName}/${environment.commandName}?launchContext=${context}`;
}

export default function SearchFiles(props: LaunchProps<{ launchContext?: LaunchContext }>) {
  const preferences = getPreferenceValues<Preferences>();
  const initialQuery = props.launchContext?.query ?? props.fallbackText ?? "";
  const [query, setQuery] = useState(initialQuery);
  const [filterID, setFilterID] = useState(props.launchContext?.filter ?? allFilter);
  const [filters, setFilters] = useState<SearchFilter[]>([]);
  const [items, setItems] = useState<SearchItem[]>([]);
  const [total, setTotal] = useState(0);
  const [issue, setIssue] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [showingDetail, setShowingDetail] = useState(preferences.showDetail);
  const [retry, setRetry] = useState(0);
  const [removed, setRemoved] = useState<Set<string>>(new Set());
  const request = useRef(0);
  const application = useRef<string | undefined>(undefined);
  const bridge = useRef<ReturnType<typeof startBridge> | undefined>(undefined);

  useEffect(() => {
    setIssue(undefined);
    setLoading(true);
    let target;
    try {
      target = findApplication(preferences.applicationPath);
    } catch (failure) {
      setLoading(false);
      setIssue((failure as Error).message);
      return;
    }
    application.current = target.application;
    const session = startBridge(
      target.executable,
      (response: BridgeResponse) => {
        if (response.filters) {
          setFilters(response.filters);
          return;
        }
        if (response.id !== request.current) return;
        setLoading(false);
        setIssue(response.error && describeError(response.error));
        setItems(response.items ?? []);
        setTotal(response.total ?? 0);
      },
      (message) => {
        setLoading(false);
        setIssue(message);
      },
    );
    bridge.current = session;
    session.send(0, { type: "filters" });
    return () => {
      bridge.current = undefined;
      session.close();
    };
  }, [preferences.applicationPath, retry]);

  useEffect(() => {
    if (!bridge.current) return;
    const id = ++request.current;
    setLoading(true);
    const filter = filterID === allFilter ? undefined : filterID;
    const timer = setTimeout(() => bridge.current?.send(id, { type: "search", query, filter, limit: resultLimit }), 60);
    return () => clearTimeout(timer);
  }, [query, filterID, retry]);

  const activeFilter = filters.find((filter) => filter.id === filterID);
  const visible = items.filter((item) => !removed.has(item.path));
  const trimmed = query.trim();
  const oilFind = (
    <Action
      title="Open Search in Oil Find"
      icon={{ fileIcon: application.current ?? "/Applications/Oil Find.app" }}
      shortcut={{ modifiers: ["cmd", "shift"], key: "o" }}
      onAction={() => open(oilFindURL(query, activeFilter), application.current)}
    />
  );
  const quicklinkAction = (trimmed || activeFilter) && (
    <Action.CreateQuicklink
      title="Save as Quicklink"
      icon={Icon.Link}
      shortcut={{ modifiers: ["cmd", "shift"], key: "l" }}
      quicklink={{
        link: quicklink(query, filterID),
        name: `Oil Find: ${[activeFilter?.name, trimmed].filter(Boolean).join(" · ")}`,
      }}
    />
  );

  function searchIn(folder: string) {
    setQuery(folderQuery(folder));
  }

  function itemActions(item: SearchItem) {
    const name = basename(item.path);
    const folder = item.isFolder ? item.path : dirname(item.path);
    const terminal = preferences.terminalApp;
    const editor = preferences.editorApp;
    return (
      <ActionPanel>
        <ActionPanel.Section>
          <Action.Open title="Open" target={item.path} />
          <Action.ShowInFinder path={item.path} />
          <Action.OpenWith path={item.path} shortcut={{ modifiers: ["cmd"], key: "o" }} />
          <Action.ToggleQuickLook shortcut={{ modifiers: ["cmd"], key: "y" }} />
          <Action
            title={showingDetail ? "Hide Details" : "Show Details"}
            icon={Icon.Sidebar}
            shortcut={{ modifiers: ["cmd"], key: "i" }}
            onAction={() => setShowingDetail((value) => !value)}
          />
        </ActionPanel.Section>
        <ActionPanel.Section title="Oil Find">
          {oilFind}
          <Action
            title={item.isFolder ? "Search in This Folder" : "Search in Enclosing Folder"}
            icon={Icon.MagnifyingGlass}
            shortcut={{ modifiers: ["cmd"], key: "f" }}
            onAction={() => searchIn(folder)}
          />
          {quicklinkAction}
        </ActionPanel.Section>
        <ActionPanel.Section title="Copy">
          <Action.CopyToClipboard
            title="Copy Path"
            content={item.path}
            shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          />
          <Action.CopyToClipboard title="Copy Name" content={name} shortcut={{ modifiers: ["cmd", "shift"], key: "n" }} />
          <Action.CopyToClipboard
            title="Copy File"
            content={{ file: item.path }}
            shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
          />
          <Action.Paste
            title="Paste Path in Frontmost App"
            content={item.path}
            shortcut={{ modifiers: ["cmd", "shift"], key: "v" }}
          />
        </ActionPanel.Section>
        <ActionPanel.Section title="Apps">
          <Action.Open
            title={`Open Folder in ${terminal?.name ?? "Terminal"}`}
            icon={terminal ? { fileIcon: terminal.path } : Icon.Terminal}
            target={folder}
            application={terminal?.bundleId ?? terminal?.path ?? "com.apple.Terminal"}
            shortcut={{ modifiers: ["cmd"], key: "t" }}
          />
          {editor && (
            <Action.Open
              title={`Open in ${editor.name}`}
              icon={{ fileIcon: editor.path }}
              target={item.path}
              application={editor.bundleId ?? editor.path}
              shortcut={{ modifiers: ["cmd"], key: "e" }}
            />
          )}
        </ActionPanel.Section>
        <ActionPanel.Section>
          <Action.Trash
            paths={item.path}
            shortcut={{ modifiers: ["ctrl"], key: "x" }}
            onTrash={() => {
              setRemoved((paths) => new Set(paths).add(item.path));
              showToast({ style: Toast.Style.Success, title: "Moved to Trash", message: name });
            }}
          />
        </ActionPanel.Section>
      </ActionPanel>
    );
  }

  const filterDropdown = (
    <List.Dropdown tooltip="Oil Find Filter" value={filterID} onChange={setFilterID}>
      <List.Dropdown.Item title="All Files" value={allFilter} icon={Icon.HardDrive} />
      {sections.map((section) => {
        const entries = filters.filter((filter) => filter.section === section.id);
        return entries.length === 0 ? null : (
          <List.Dropdown.Section key={section.id} title={section.title}>
            {entries.map((filter) => (
              <List.Dropdown.Item key={filter.id} title={filter.name} value={filter.id} icon={filterIcon(filter)} />
            ))}
          </List.Dropdown.Section>
        );
      })}
    </List.Dropdown>
  );

  const countLabel = total > visible.length ? `${visible.length} of ${total.toLocaleString()}` : String(visible.length);

  return (
    <List
      searchText={query}
      onSearchTextChange={setQuery}
      filtering={false}
      isLoading={loading}
      isShowingDetail={showingDetail && visible.length > 0}
      searchBarPlaceholder="Search with Oil Find… (*.pdf, in:~/Documents, dm:week, size:>10mb)"
      searchBarAccessory={filterDropdown}
    >
      {issue ? (
        <List.EmptyView
          title="Search Unavailable"
          description={issue}
          icon={Icon.ExclamationMark}
          actions={
            <ActionPanel>
              <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => setRetry((value) => value + 1)} />
              {oilFind}
              <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          title={loading ? "Searching Oil Find…" : "No Files Found"}
          description={loading ? undefined : "Try another query or filter, or open the search in Oil Find."}
          icon={Icon.MagnifyingGlass}
          actions={
            <ActionPanel>
              {oilFind}
              {quicklinkAction}
            </ActionPanel>
          }
        />
      )}
      {!issue && visible.length > 0 && (
        <List.Section title={trimmed || activeFilter ? "Results" : "Recent Files"} subtitle={countLabel}>
          {visible.map((item) => (
            <List.Item
              key={item.path}
              title={basename(item.path) || item.path}
              subtitle={showingDetail ? undefined : displayPath(item.path)}
              icon={{ fileIcon: item.path }}
              quickLook={{ path: item.path, name: basename(item.path) }}
              accessories={
                showingDetail
                  ? undefined
                  : [
                      ...(item.isFolder ? [] : [{ text: formatSize(item.size) }]),
                      { date: new Date(item.modified * 1000), tooltip: `Modified ${formatDate(item.modified)}` },
                    ]
              }
              detail={showingDetail ? <ItemDetail item={item} /> : undefined}
              actions={itemActions(item)}
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}
