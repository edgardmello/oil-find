import {
  Action,
  ActionPanel,
  Color,
  Icon,
  LaunchType,
  List,
  getPreferenceValues,
  launchCommand,
  openExtensionPreferences,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { IndexStatus, findApplication, requestOnce } from "./bridge";
import { tildePath } from "./paths";
import { formatDate, formatSize } from "./preview";

// The same wording as Oil Find's "Not Covered" summary.
const gapTitles: Record<string, string> = {
  noAccess: "Folders without access",
  dependency: "Dependency folders",
  packages: "Inside packages",
  library: "Library",
  system: "System",
  userExcluded: "In paths you excluded",
  fileType: "Excluded file types",
  cloud: "Cloud-only folders",
  volumes: "External and network volumes",
};

const fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

export default function IndexStatusCommand() {
  const { applicationPath } = getPreferenceValues<{ applicationPath?: string }>();
  const [indexes, setIndexes] = useState<IndexStatus[]>();
  const [issue, setIssue] = useState<string>();
  const [application, setApplication] = useState<string>();
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    setIssue(undefined);
    setIndexes(undefined);
    try {
      const target = findApplication(applicationPath);
      setApplication(target.application);
      requestOnce(target.executable, { type: "status" })
        .then((response) => setIndexes(response.indexes ?? []))
        .catch((failure: Error) => setIssue(failure.message));
    } catch (failure) {
      setIssue((failure as Error).message);
    }
  }, [applicationPath, retry]);

  const refresh = (
    <Action
      title="Refresh"
      icon={Icon.ArrowClockwise}
      shortcut={{ modifiers: ["cmd"], key: "r" }}
      onAction={() => setRetry((value) => value + 1)}
    />
  );

  return (
    <List isLoading={!indexes && !issue} isShowingDetail={!!indexes?.length}>
      {issue && (
        <List.EmptyView
          title="Status Unavailable"
          description={issue}
          icon={Icon.ExclamationMark}
          actions={
            <ActionPanel>
              {refresh}
              <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
            </ActionPanel>
          }
        />
      )}
      {indexes?.map((index) => {
        const noAccess = index.gaps.find((gap) => gap.reason === "noAccess");
        return (
          <List.Item
            key={index.id}
            title={index.name}
            subtitle={index.id === "startup" ? "Startup volume" : undefined}
            icon={{ source: index.id === "startup" ? Icon.ComputerChip : Icon.HardDrive, tintColor: index.connected ? undefined : Color.SecondaryText }}
            accessories={[
              ...(index.connected ? [] : [{ tag: { value: "Offline", color: Color.SecondaryText } }]),
              ...(noAccess ? [{ icon: { source: Icon.Warning, tintColor: Color.Orange }, tooltip: "Some folders are not readable" }] : []),
            ]}
            detail={
              <List.Item.Detail
                markdown={
                  noAccess
                    ? `Oil Find cannot read **${noAccess.count.toLocaleString()}** folders here, so their files are missing from search. Give Oil Find Full Disk Access to include them.\n\n${noAccess.examples.map((path) => `- \`${tildePath(path)}\``).join("\n")}`
                    : undefined
                }
                metadata={
                  <List.Item.Detail.Metadata>
                    <List.Item.Detail.Metadata.Label title="Indexed items" text={index.items.toLocaleString()} />
                    <List.Item.Detail.Metadata.Label title="Root" text={tildePath(index.root)} />
                    <List.Item.Detail.Metadata.Label title="Index file" text={formatSize(index.fileSize)} />
                    {index.saved && <List.Item.Detail.Metadata.Label title="Last saved" text={formatDate(index.saved)} />}
                    <List.Item.Detail.Metadata.Label title="Connected" text={index.connected ? "Yes" : "No, searching the saved catalog"} />
                    {index.gaps.length > 0 && <List.Item.Detail.Metadata.Separator />}
                    {index.gaps.map((gap) => (
                      <List.Item.Detail.Metadata.Label
                        key={gap.reason}
                        title={gapTitles[gap.reason] ?? gap.reason}
                        text={gap.count.toLocaleString()}
                        icon={gap.reason === "noAccess" ? { source: Icon.Warning, tintColor: Color.Orange } : undefined}
                      />
                    ))}
                  </List.Item.Detail.Metadata>
                }
              />
            }
            actions={
              <ActionPanel>
                <Action
                  title="Search This Index"
                  icon={Icon.MagnifyingGlass}
                  onAction={() =>
                    launchCommand({
                      name: "search-files",
                      type: LaunchType.UserInitiated,
                      context: index.id === "startup" ? {} : { filter: "drive:" + index.id },
                    })
                  }
                />
                {noAccess && <Action.Open title="Open Full Disk Access Settings" icon={Icon.Lock} target={fullDiskAccess} />}
                {application && <Action.Open title="Open Oil Find" icon={{ fileIcon: application }} target={application} />}
                {refresh}
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
