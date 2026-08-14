import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const helperPath = fileURLToPath(new URL("../scripts/thinkscape-release-tags.sh", import.meta.url));

function inspectTags(tags: string[]) {
  const output = execFileSync(
    "bash",
    [
      "-c",
      `
set -euo pipefail
source "$1"
shift
for tag in "$@"; do
  version="\${tag#v}"
  printf '%s\\t%s\\t%s\\t%s\\n' \\
    "$tag" \\
    "$(thinkscape_is_supported_release_tag "$tag" && printf true || printf false)" \\
    "$(thinkscape_release_package_version "$tag")" \\
    "$(thinkscape_is_latest_release_version "$version" && printf true || printf false)"
done
`,
      "thinkscape-release-tags-test",
      helperPath,
      ...tags,
    ],
    { encoding: "utf8" },
  );

  return output
    .trim()
    .split("\n")
    .map((line) => {
      const [tag, supported, packageVersion, latest] = line.split("\t");
      return { tag, supported, packageVersion, latest };
    });
}

describe("Thinkscape release tag semantics", () => {
  it("accepts correction tags and maps them to the base package version", () => {
    expect(inspectTags(["v2026.7.1-2"])).toEqual([
      {
        tag: "v2026.7.1-2",
        supported: "true",
        packageVersion: "2026.7.1",
        latest: "true",
      },
    ]);
  });

  it("preserves stable and beta package versions", () => {
    expect(inspectTags(["v2026.7.1", "v2026.7.1-beta.1"])).toEqual([
      {
        tag: "v2026.7.1",
        supported: "true",
        packageVersion: "2026.7.1",
        latest: "true",
      },
      {
        tag: "v2026.7.1-beta.1",
        supported: "true",
        packageVersion: "2026.7.1-beta.1",
        latest: "true",
      },
    ]);
  });

  it("rejects malformed and zero-suffix release tags", () => {
    expect(inspectTags(["v2026.7.1-0", "v2026.7.1-rc.1"])).toEqual([
      {
        tag: "v2026.7.1-0",
        supported: "false",
        packageVersion: "2026.7.1-0",
        latest: "false",
      },
      {
        tag: "v2026.7.1-rc.1",
        supported: "false",
        packageVersion: "2026.7.1-rc.1",
        latest: "false",
      },
    ]);
  });
});
