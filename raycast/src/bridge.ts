import { spawn, spawnSync } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

// Must match OilFindRaycastProtocol in the app's Info.plist.
const protocolVersion = "2";

export interface SearchItem {
  path: string;
  kind?: string;
  isFolder: boolean;
  size: number;
  modified: number;
}

export interface SearchFilter {
  id: string;
  name: string;
  section: "kind" | "quick" | "folder" | "saved";
  symbol?: string;
  query?: string;
}

export interface BridgeResponse {
  id: number;
  items?: SearchItem[];
  total?: number;
  filters?: SearchFilter[];
  error?: string;
}

export interface OilFindApplication {
  application: string;
  executable: string;
}

/** The bundle of an Oil Find that is already running, so a build outside Applications works too. */
function runningApplication() {
  const processes = spawnSync("/bin/ps", ["-Axo", "comm="], { encoding: "utf8" }).stdout ?? "";
  const executable = processes.split("\n").find((line) => line.endsWith(".app/Contents/MacOS/OilFind"));
  return executable?.slice(0, -"/Contents/MacOS/OilFind".length);
}

export function findApplication(applicationPath: string | undefined): OilFindApplication {
  const configured = applicationPath?.trim();
  const installed = ["/Applications", join(homedir(), "Applications")].flatMap((folder) =>
    ["Oil Find.app", "Oil Find Preview.app"].map((name) => join(folder, name)),
  );
  const running = runningApplication();
  const candidates = configured
    ? [configured.replace(/^~\//, homedir() + "/")]
    : [...(running ? [running] : []), ...installed];
  let outdated = false;
  for (const candidate of candidates) {
    const executable = join(candidate, "Contents", "MacOS", "OilFind");
    try {
      accessSync(executable, constants.X_OK);
    } catch {
      continue;
    }
    const version = spawnSync(
      "/usr/libexec/PlistBuddy",
      ["-c", "Print :OilFindRaycastProtocol", join(candidate, "Contents", "Info.plist")],
      { encoding: "utf8" },
    );
    if (version.status === 0 && version.stdout.trim() === protocolVersion) {
      return { application: candidate, executable };
    }
    outdated = true;
  }
  throw new Error(
    outdated
      ? "This Oil Find version does not support Raycast yet. Update Oil Find, or set Oil Find App Path to a newer build."
      : "Oil Find was not found. Install it in Applications, or set Oil Find App Path in the extension preferences.",
  );
}

type Request = { type: "search"; query: string; filter?: string; limit: number } | { type: "filters" };

export function startBridge(
  executable: string,
  onResponse: (response: BridgeResponse) => void,
  onError: (message: string) => void,
) {
  const child = spawn(executable, ["--raycast-search"], { stdio: ["pipe", "pipe", "ignore"] });
  const output = createInterface({ input: child.stdout });
  // Filter requests queue up; only the newest search is worth sending while one is in flight.
  const queue: string[] = [];
  let latestSearch: string | undefined;
  let busy = false;
  let closed = false;
  let timeout: NodeJS.Timeout | undefined;

  function close() {
    closed = true;
    clearTimeout(timeout);
    output.close();
    child.kill();
  }

  function fail(message: string) {
    if (closed) return;
    close();
    onError(message);
  }

  function flush() {
    if (closed || busy) return;
    const line = queue.shift() ?? latestSearch;
    if (line === undefined) return;
    if (line === latestSearch) latestSearch = undefined;
    busy = true;
    child.stdin.write(line + "\n");
    // The first request loads the whole index, which can take a while on large disks.
    timeout = setTimeout(() => fail("Oil Find did not respond. Retry, or update Oil Find."), 30_000);
  }

  output.on("line", (line) => {
    clearTimeout(timeout);
    busy = false;
    try {
      onResponse(JSON.parse(line) as BridgeResponse);
    } catch {
      fail("Oil Find returned an unexpected response. Update Oil Find and retry.");
      return;
    }
    flush();
  });
  child.on("error", () => fail("Could not start Oil Find. Check Oil Find App Path and retry."));
  child.stdin.on("error", () => fail("Lost the connection to Oil Find. Retry."));
  child.on("close", () => fail("Oil Find stopped responding. Retry."));

  return {
    send(id: number, request: Request) {
      const line = JSON.stringify({ id, ...request });
      if (request.type === "search") latestSearch = line;
      else queue.push(line);
      flush();
    },
    close,
  };
}
