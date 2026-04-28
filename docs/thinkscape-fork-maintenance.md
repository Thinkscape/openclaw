# Thinkscape fork maintenance

The Thinkscape fork tracks upstream OpenClaw releases and publishes patched Docker images under `ghcr.io/thinkscape/openclaw`.

## Patch queue layout

Fork-specific source changes live in an explicit patch queue on the fork's default branch:

```text
thinkscape/patches/series
thinkscape/patches/0001-subagent-gateway-timeout.patch
thinkscape/patches/0002-session-write-lock-config.patch
thinkscape/patches/0003-sandbox-no-new-privileges.patch
thinkscape/patches/0004-skill-prompt-path-alias.patch
```

`series` is the ordered list of patches to apply. Blank lines and `#` comments are ignored.

The release-sync workflow creates disposable release branches from upstream release tags, preserves fork maintenance files, applies the patch queue with `git am --3way`, regenerates schema artifacts, runs targeted validation, tags the patched release, and dispatches the Docker release workflow.

## Why patches live on `main`

The default branch is the source of truth for maintenance automation: workflows, release scripts, docs, and patch files. This keeps the moving parts visible in ordinary PRs and lets GitHub Actions read the patch queue directly from the workflow checkout.

Release branches are generated outputs. Do not hand-maintain release branches except as a temporary conflict-resolution workspace.

## Refreshing a patch after an upstream conflict

1. Start from a clean checkout of the fork default branch.
2. Run a dry sync for the failing upstream tag:

   ```bash
   RELEASE_TAG=vYYYY.M.DD SYNC_DRY_RUN=1 bash scripts/thinkscape-upstream-release-sync.sh
   ```

3. If a patch fails, create or reuse the generated `release/vYYYY.M.DD-thinkscape` branch as a temporary workspace.
4. Apply earlier patches from `thinkscape/patches/series` if needed.
5. Re-apply the failing change manually against the upstream release code.
6. Run the targeted tests named by the release-sync script.
7. Commit the refreshed change as one commit.
8. Regenerate the patch file:

   ```bash
   git format-patch -1 --stdout HEAD > thinkscape/patches/000N-name.patch
   ```

9. Return to `main`, replace the patch file, commit, push, and rerun the dry sync.

## Adding or removing patches

- Add a patch by writing a numbered `*.patch` file and adding it to `thinkscape/patches/series`.
- Remove a patch by deleting its file and removing it from `series`.
- Keep patch filenames stable unless the patch's purpose changes.
- Prefer upstream PRs or plugin/config extension points over permanent fork patches.

## Generated files

Where practical, keep generated artifacts out of patch files and let release sync run `pnpm config:schema:gen` after patch application. If a generated artifact must be included to make the patch apply or tests pass before generation, keep it as small as possible.
