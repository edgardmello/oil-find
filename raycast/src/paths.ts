import { homedir } from "node:os";
import { dirname } from "node:path";

const home = homedir();

export function tildePath(path: string) {
  return path === home ? "~" : path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
}

/** The enclosing folder, or the full path when `full` is set. */
export function displayPath(path: string, full = false) {
  return tildePath(full ? path : dirname(path));
}

/** Oil Find's `in:` operator, quoted so spaces survive. */
export function folderQuery(folder: string) {
  return `in:"${tildePath(folder).replace(/"/g, '\\"')}" `;
}
