import {
  Action,
  ActionPanel,
  Alert,
  Color,
  Icon,
  List,
  confirmAlert,
  getPreferenceValues,
  openExtensionPreferences,
  showToast,
  Toast,
} from "@raycast/api";
import { basename } from "node:path";
import { useEffect, useRef, useState } from "react";
import { SearchItem, findApplication, startBridge, updateStash } from "./bridge";
import { displayPath } from "./paths";
import { ItemDetail, formatDate, formatSize } from "./preview";

export default function Stash() {
  const { applicationPath } = getPreferenceValues<{ applicationPath?: string }>();
  const [items, setItems] = useState<SearchItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [issue, setIssue] = useState<string>();
  const [showingDetail, setShowingDetail] = useState(false);
  const [retry, setRetry] = useState(0);
  const application = useRef<string | undefined>(undefined);
  const bridge = useRef<ReturnType<typeof startBridge> | undefined>(undefined);
  const request = useRef(0);
  const pendingCopy = useRef<number | undefined>(undefined);

  useEffect(() => {
    setIssue(undefined);
    let target;
    try {
      target = findApplication(applicationPath);
    } catch (failure) {
      setLoading(false);
      setIssue((failure as Error).message);
      return;
    }
    application.current = target.application;
    const session = startBridge(
      target.executable,
      (response) => {
        if (response.stash) {
          setItems(response.stash);
          setLoading(false);
        } else if (response.copied !== undefined && response.id === pendingCopy.current) {
          showToast(
            response.copied > 0
              ? { style: Toast.Style.Success, title: `Copied ${response.copied} files` }
              : { style: Toast.Style.Failure, title: "None of the stashed files are available" },
          );
        }
      },
      (message) => {
        setLoading(false);
        setIssue(message);
      },
    );
    bridge.current = session;
    session.send(++request.current, { type: "stash" });
    return () => {
      bridge.current = undefined;
      session.close();
    };
  }, [applicationPath, retry]);

  // Oil Find saves the stash a moment after it receives a change.
  function reload() {
    setLoading(true);
    for (const delay of [250, 1000]) {
      setTimeout(() => bridge.current?.send(++request.current, { type: "stash" }), delay);
    }
  }

  async function change(action: "remove" | "clear", paths: string[] = []) {
    if (!application.current) return;
    try {
      if (action === "clear") await updateStash(application.current, "clear");
      else await updateStash(application.current, "remove", paths);
      setItems((current) => (action === "clear" ? [] : current.filter((item) => !paths.includes(item.path))));
      reload();
    } catch {
      await showToast({ style: Toast.Style.Failure, title: "Could not reach Oil Find" });
    }
  }

  async function clear() {
    const confirmed = await confirmAlert({
      title: "Clear the Oil Find stash?",
      message: "The files stay where they are. Only the stash list is emptied.",
      primaryAction: { title: "Clear Stash", style: Alert.ActionStyle.Destructive },
    });
    if (confirmed) await change("clear");
  }

  const available = items.filter((item) => !item.missing);
  const showInOilFind = (
    <Action
      title="Show Stash in Oil Find"
      icon={{ fileIcon: application.current ?? "/Applications/Oil Find.app" }}
      shortcut={{ modifiers: ["cmd", "shift"], key: "o" }}
      onAction={() => application.current && updateStash(application.current, "show")}
    />
  );
  const stashActions = (
    <>
      <Action
        title={`Copy All ${available.length} Files`}
        icon={Icon.CopyClipboard}
        shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
        onAction={() => {
          pendingCopy.current = ++request.current;
          bridge.current?.send(pendingCopy.current, { type: "copyFiles", paths: available.map((item) => item.path) });
        }}
      />
      {showInOilFind}
      <Action
        title="Clear Stash"
        icon={Icon.Trash}
        style={Action.Style.Destructive}
        shortcut={{ modifiers: ["ctrl", "shift"], key: "x" }}
        onAction={clear}
      />
    </>
  );

  return (
    <List
      isLoading={loading}
      isShowingDetail={showingDetail && items.length > 0}
      searchBarPlaceholder="Filter stashed files…"
    >
      {issue ? (
        <List.EmptyView
          title="Stash Unavailable"
          description={issue}
          icon={Icon.ExclamationMark}
          actions={
            <ActionPanel>
              <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => setRetry((value) => value + 1)} />
              <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          title="No Stashed Files"
          description="Add files with ⌘S in Search Files with Oil Find, or from the Oil Find panel."
          icon={Icon.Tray}
          actions={<ActionPanel>{showInOilFind}</ActionPanel>}
        />
      )}
      <List.Section title="Oil Find Stash" subtitle={items.length ? String(items.length) : undefined}>
        {items.map((item) => (
          <List.Item
            key={item.path}
            title={basename(item.path)}
            subtitle={showingDetail ? undefined : displayPath(item.path)}
            icon={item.missing ? { source: Icon.QuestionMarkCircle, tintColor: Color.SecondaryText } : { fileIcon: item.path }}
            quickLook={item.missing ? undefined : { path: item.path, name: basename(item.path) }}
            keywords={[displayPath(item.path)]}
            accessories={
              showingDetail
                ? undefined
                : item.missing
                  ? [{ tag: { value: "Unavailable", color: Color.Orange } }]
                  : [
                      ...(item.isFolder ? [] : [{ text: formatSize(item.size) }]),
                      { date: new Date(item.modified * 1000), tooltip: `Modified ${formatDate(item.modified)}` },
                    ]
            }
            detail={showingDetail && !item.missing ? <ItemDetail item={item} /> : undefined}
            actions={
              <ActionPanel>
                <ActionPanel.Section>
                  {!item.missing && <Action.Open title="Open" target={item.path} />}
                  {!item.missing && <Action.ShowInFinder path={item.path} />}
                  {!item.missing && <Action.ToggleQuickLook shortcut={{ modifiers: ["cmd"], key: "y" }} />}
                  <Action
                    title={showingDetail ? "Hide Details" : "Show Details"}
                    icon={Icon.Sidebar}
                    shortcut={{ modifiers: ["cmd"], key: "i" }}
                    onAction={() => setShowingDetail((value) => !value)}
                  />
                </ActionPanel.Section>
                <ActionPanel.Section title="Stash">
                  {stashActions}
                  <Action
                    title="Remove from Stash"
                    icon={Icon.MinusCircle}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                    onAction={() => change("remove", [item.path])}
                  />
                </ActionPanel.Section>
                <ActionPanel.Section title="Copy">
                  {!item.missing && (
                    <Action.CopyToClipboard
                      title="Copy File"
                      content={{ file: item.path }}
                      shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                    />
                  )}
                  <Action.CopyToClipboard title="Copy Path" content={item.path} />
                </ActionPanel.Section>
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
