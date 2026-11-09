import { Action, ActionPanel, Detail, Icon, Toast, showToast, useNavigation } from "@raycast/api";
import { basename } from "node:path";
import { useState } from "react";
import { FileScript, ScriptRun, requestOnce } from "./bridge";

// Scripts may run for a while; Oil Find itself has no time limit for them.
const scriptTimeout = 10 * 60_000;

function fence(text: string) {
  const longest = Math.max(2, ...(text.match(/`+/g) ?? []).map((run) => run.length));
  return "`".repeat(longest + 1);
}

function ScriptOutput({ script, files, run }: { script: FileScript; files: string[]; run: ScriptRun }) {
  const marker = fence(run.output);
  const status =
    run.status === "exited"
      ? `Exited with code ${run.code}`
      : run.status === "signaled"
        ? `Stopped by signal ${run.code}`
        : run.status === "stopped"
          ? "Stopped"
          : "Could not run";
  const output = run.output.trim() ? `${marker}\n${run.output}\n${marker}` : "*No output.*";
  const truncated = run.truncated ? "\n\n*Output truncated at 64 KB, like in Oil Find.*" : "";
  return (
    <Detail
      navigationTitle={script.name}
      markdown={`## ${script.name}\n\n${output}${truncated}`}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Status" text={status} />
          <Detail.Metadata.Label title="Script" text={script.path} />
          <Detail.Metadata.TagList title="Files">
            {files.slice(0, 10).map((file) => (
              <Detail.Metadata.TagList.Item key={file} text={basename(file)} />
            ))}
          </Detail.Metadata.TagList>
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action.CopyToClipboard title="Copy Output" content={run.output} />
        </ActionPanel>
      }
    />
  );
}

/** The file scripts from Oil Find's settings that accept these files, like the panel's Scripts menu. */
export function ScriptsSubmenu({
  executable,
  paths,
  title = "Run Oil Find Script",
}: {
  executable?: string;
  paths: string[];
  title?: string;
}) {
  const [scripts, setScripts] = useState<FileScript[]>();
  const { push } = useNavigation();
  if (!executable) return null;

  async function load() {
    if (scripts) return;
    try {
      setScripts((await requestOnce(executable!, { type: "scripts", paths })).scripts ?? []);
    } catch {
      setScripts([]);
    }
  }

  async function run(script: FileScript) {
    const toast = await showToast({ style: Toast.Style.Animated, title: `Running ${script.name}…` });
    try {
      const response = await requestOnce(executable!, { type: "runScript", script: script.path, paths }, scriptTimeout);
      const result = response.run!;
      toast.style = result.status === "exited" && result.code === 0 ? Toast.Style.Success : Toast.Style.Failure;
      toast.title = result.status === "exited" && result.code === 0 ? `${script.name} finished` : `${script.name} failed`;
      push(<ScriptOutput script={script} files={paths} run={result} />);
    } catch (failure) {
      toast.style = Toast.Style.Failure;
      toast.title = `Could not run ${script.name}`;
      toast.message = (failure as Error).message;
    }
  }

  return (
    <ActionPanel.Submenu
      title={title}
      icon={Icon.Terminal}
      shortcut={{ modifiers: ["cmd", "shift"], key: "r" }}
      isLoading={scripts === undefined}
      onOpen={load}
    >
      {scripts?.length === 0 && <Action title={paths.length > 1 ? "No Scripts Accept These Files" : "No Scripts Accept This File"} icon={Icon.Info} onAction={() => undefined} />}
      {scripts?.map((script) => (
        <Action key={script.path} title={script.name} icon={Icon.Code} onAction={() => run(script)} />
      ))}
    </ActionPanel.Submenu>
  );
}
