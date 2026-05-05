#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-openclaw/openclaw}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
FORK_REPO="${FORK_REPO:-${GITHUB_REPOSITORY:-Thinkscape/openclaw}}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
DOCKER_RELEASE_WORKFLOW="${DOCKER_RELEASE_WORKFLOW:-docker-release.yml}"
TARGET_IMAGE="${TARGET_IMAGE:-ghcr.io/thinkscape/openclaw}"
PATCH_SERIES_FILE="${PATCH_SERIES_FILE:-thinkscape/patches/series}"
RELEASE_TAG="${RELEASE_TAG:-}"
SYNC_DRY_RUN="${SYNC_DRY_RUN:-0}"
COPILOT_ASSIGNMENT_TOKEN="${COPILOT_ASSIGNMENT_TOKEN:-}"
WORKFLOW_POLL_SECONDS="${WORKFLOW_POLL_SECONDS:-30}"
WORKFLOW_MAX_POLLS="${WORKFLOW_MAX_POLLS:-240}"

log() {
  printf '[release-sync] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

latest_upstream_release_tag() {
  gh api "repos/${UPSTREAM_REPO}/releases/latest" --jq '.tag_name'
}

open_or_update_issue() {
  local title="$1"
  local body_file="$2"
  local existing issue_url issue_number

  existing="$(gh issue list \
    --repo "${FORK_REPO}" \
    --state open \
    --search "\"${title}\" in:title" \
    --json number,title | jq -r --arg title "${title}" 'map(select(.title == $title))[0].number // empty')"

  if [[ -n "${existing}" ]]; then
    issue_number="${existing}"
    gh issue comment "${issue_number}" --repo "${FORK_REPO}" --body-file "${body_file}" >/dev/null
    printf '%s\n' "${issue_number}"
    return 0
  fi

  issue_url="$(gh issue create \
    --repo "${FORK_REPO}" \
    --title "${title}" \
    --body-file "${body_file}")"
  issue_number="$(gh issue view "${issue_url}" --repo "${FORK_REPO}" --json number --jq '.number')"
  printf '%s\n' "${issue_number}"
}

maybe_assign_issue_to_copilot() {
  local issue_number="$1"
  if [[ -z "${COPILOT_ASSIGNMENT_TOKEN}" ]]; then
    return 0
  fi
  log "Attempting Copilot assignment for issue #${issue_number}"
  if ! GH_TOKEN="${COPILOT_ASSIGNMENT_TOKEN}" \
    gh issue edit "${issue_number}" --repo "${FORK_REPO}" --add-assignee copilot >/dev/null 2>&1; then
    log "Copilot assignment failed for issue #${issue_number}; leaving issue open for manual follow-up"
  fi
}

fail_with_issue() {
  local phase="$1"
  local release_tag="$2"
  local detail_file="$3"
  local title issue_number
  title="[release-sync] ${release_tag}: ${phase} failed"
  issue_number="$(open_or_update_issue "${title}" "${detail_file}")"
  maybe_assign_issue_to_copilot "${issue_number}"
  printf 'Opened or updated issue #%s for failure: %s\n' "${issue_number}" "${phase}" >&2
  exit 1
}

verify_version_alignment() {
  local upstream_commit="$1"
  local release_tag="$2"
  local expected="${release_tag#v}"
  local actual

  actual="$(git show "${upstream_commit}:package.json" | jq -r '.version')"
  if [[ "${actual}" != "${expected}" ]]; then
    local detail_file
    detail_file="$(mktemp)"
    cat >"${detail_file}" <<EOF
Upstream release/version mismatch detected.

- upstream repo: ${UPSTREAM_REPO}
- release tag: ${release_tag}
- expected version from tag: ${expected}
- package.json version at upstream commit ${upstream_commit}: ${actual}

The automation intentionally refuses to publish a forked image when the upstream
release tag and package.json version diverge.
EOF
    fail_with_issue "version alignment" "${release_tag}" "${detail_file}"
  fi

  printf '%s\n' "${actual}"
}

cancel_inflight_docker_release_runs() {
  local runs run_id
  runs="$(gh run list \
    --repo "${FORK_REPO}" \
    --workflow "Docker Release" \
    --limit 20 \
    --json databaseId,status \
    --jq '.[] | select(.status == "in_progress" or .status == "queued" or .status == "pending") | .databaseId')"
  if [[ -z "${runs}" ]]; then
    return 0
  fi
  while IFS= read -r run_id; do
    [[ -z "${run_id}" ]] && continue
    log "Cancelling in-flight Docker Release run ${run_id}"
    gh run cancel "${run_id}" --repo "${FORK_REPO}" >/dev/null || true
  done <<<"${runs}"
}

dispatch_docker_release() {
  local release_tag="$1"
  local dispatched_at="$2"
  gh workflow run "${DOCKER_RELEASE_WORKFLOW}" \
    --repo "${FORK_REPO}" \
    --ref "${DEFAULT_BRANCH}" \
    -f "tag=${release_tag}" \
    >/dev/null

  local run_id=""
  for _ in $(seq 1 30); do
    run_id="$(gh run list \
      --repo "${FORK_REPO}" \
      --workflow "Docker Release" \
      --event workflow_dispatch \
      --limit 20 \
      --json databaseId,createdAt | \
      jq -r --arg after "${dispatched_at}" 'map(select(.createdAt >= $after)) | sort_by(.createdAt) | last.databaseId // empty')"
    if [[ -n "${run_id}" ]]; then
      printf '%s\n' "${run_id}"
      return 0
    fi
    sleep 5
  done

  local detail_file
  detail_file="$(mktemp)"
  cat >"${detail_file}" <<EOF
Timed out waiting for Docker Release workflow run to appear after dispatch.

- release tag: ${release_tag}
- dispatched_at: ${dispatched_at}
- workflow: ${DOCKER_RELEASE_WORKFLOW}
- repository: ${FORK_REPO}
EOF
  fail_with_issue "docker release dispatch" "${release_tag}" "${detail_file}"
}

wait_for_run_completion() {
  local run_id="$1"
  local release_tag="$2"
  local status conclusion

  for _ in $(seq 1 "${WORKFLOW_MAX_POLLS}"); do
    status="$(gh api "repos/${FORK_REPO}/actions/runs/${run_id}" --jq '.status')"
    conclusion="$(gh api "repos/${FORK_REPO}/actions/runs/${run_id}" --jq '.conclusion // ""')"
    if [[ "${status}" == "completed" ]]; then
      if [[ "${conclusion}" == "success" ]]; then
        return 0
      fi
      local detail_file
      detail_file="$(mktemp)"
      {
        printf 'Docker Release workflow failed.\n\n'
        printf -- '- release tag: %s\n' "${release_tag}"
        printf -- '- run id: %s\n' "${run_id}"
        printf -- '- conclusion: %s\n\n' "${conclusion}"
        gh run view "${run_id}" --repo "${FORK_REPO}" --log-failed || true
      } >"${detail_file}"
      fail_with_issue "docker release" "${release_tag}" "${detail_file}"
    fi
    sleep "${WORKFLOW_POLL_SECONDS}"
  done

  local detail_file
  detail_file="$(mktemp)"
  cat >"${detail_file}" <<EOF
Timed out waiting for Docker Release workflow run ${run_id} to complete.

- release tag: ${release_tag}
- workflow run: ${run_id}
- poll interval seconds: ${WORKFLOW_POLL_SECONDS}
- max polls: ${WORKFLOW_MAX_POLLS}
EOF
  fail_with_issue "docker release timeout" "${release_tag}" "${detail_file}"
}

verify_published_images() {
  local version="$1"
  local detail_file
  local latest_digest=""
  local version_digest=""

  if ! docker buildx imagetools inspect "${TARGET_IMAGE}:${version}" >/dev/null 2>&1; then
    detail_file="$(mktemp)"
    cat >"${detail_file}" <<EOF
Expected published image is missing after Docker Release completed.

- image: ${TARGET_IMAGE}:${version}
- note: version tag should be published before latest
EOF
    fail_with_issue "published image verification" "v${version}" "${detail_file}"
  fi

  if [[ "${version}" =~ ^[0-9]{4}\.[1-9][0-9]*\.[1-9][0-9]*(-beta\.[1-9][0-9]*)?$ ]]; then
    version_digest="$(docker buildx imagetools inspect "${TARGET_IMAGE}:${version}" | sed -n 's/^Digest:[[:space:]]*//p' | head -n 1)"
    latest_digest="$(docker buildx imagetools inspect "${TARGET_IMAGE}:latest" | sed -n 's/^Digest:[[:space:]]*//p' | head -n 1)"
    if [[ -z "${version_digest}" || -z "${latest_digest}" || "${version_digest}" != "${latest_digest}" ]]; then
      detail_file="$(mktemp)"
      cat >"${detail_file}" <<EOF
Latest tag does not point at the rebuilt upstream release manifest.

- image: ${TARGET_IMAGE}:${version}
- version digest: ${version_digest:-<missing>}
- latest digest: ${latest_digest:-<missing>}
EOF
      fail_with_issue "latest digest verification" "v${version}" "${detail_file}"
    fi
    return 0
  fi

  if ! docker buildx imagetools inspect "${TARGET_IMAGE}:latest" >/dev/null 2>&1; then
    detail_file="$(mktemp)"
    cat >"${detail_file}" <<EOF
Expected latest tag is missing after Docker Release completed.

- image: ${TARGET_IMAGE}:latest
- source version: ${version}
EOF
    fail_with_issue "latest tag verification" "v${version}" "${detail_file}"
  fi
}

main() {
  require_cmd git
  require_cmd gh
  require_cmd jq
  require_cmd docker

  local release_tag="${RELEASE_TAG}"
  local explicit_release_tag="${RELEASE_TAG}"
  if [[ -z "${release_tag}" ]]; then
    release_tag="$(latest_upstream_release_tag)"
  fi
  if [[ -z "${release_tag}" || "${release_tag}" != v* ]]; then
    printf 'invalid release tag: %s\n' "${release_tag}" >&2
    exit 1
  fi

  local release_version="${release_tag#v}"
  local release_branch="release/${release_tag}-thinkscape"
  local upstream_tag_ref="refs/thinkscape/upstream-release-sync/${release_tag}"

  log "Syncing upstream release ${release_tag}"

  git remote add upstream "${UPSTREAM_URL}" 2>/dev/null || true
  git fetch origin --tags --prune

  local upstream_commit
  # Keep upstream release tags out of the fork's local tag namespace because
  # the fork intentionally reuses upstream tag names for patched releases.
  git update-ref -d "${upstream_tag_ref}" >/dev/null 2>&1 || true
  git fetch --no-tags upstream "refs/tags/${release_tag}:${upstream_tag_ref}"
  upstream_commit="$(git rev-parse "${upstream_tag_ref}^{}")"
  if [[ -z "${upstream_commit}" ]]; then
    printf 'could not resolve upstream tag %s\n' "${release_tag}" >&2
    exit 1
  fi

  verify_version_alignment "${upstream_commit}" "${release_tag}" >/dev/null

  local remote_branch_sha remote_tag_sha
  remote_branch_sha="$(git ls-remote origin "refs/heads/${release_branch}" | awk '{print $1}')"
  remote_tag_sha="$(git ls-remote origin "refs/tags/${release_tag}^{}" | awk '{print $1}')"
  if [[ -z "${explicit_release_tag}" && -n "${remote_branch_sha}" && -n "${remote_tag_sha}" && "${remote_branch_sha}" == "${remote_tag_sha}" ]]; then
    if docker buildx imagetools inspect "${TARGET_IMAGE}:${release_version}" >/dev/null 2>&1; then
      log "Fork release ${release_tag} is already published at ${TARGET_IMAGE}:${release_version}; skipping"
      exit 0
    fi
  fi

  git checkout -B "${release_branch}" "origin/${DEFAULT_BRANCH}"
  # Keep workflow files on the fork's main lineage so the default GitHub
  # Actions token can push release refs without extra workflows permission.
  git restore --source "${upstream_commit}" --staged --worktree -- . \
    ':(exclude).github/workflows' \
    ':(exclude)scripts/thinkscape-upstream-release-sync.sh' \
    ':(exclude)thinkscape/patches'
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git commit --no-verify -m "chore(release-sync): stage upstream snapshot for ${release_tag}"
  fi

  if [[ ! -f "${PATCH_SERIES_FILE}" ]]; then
    printf 'patch series file not found: %s\n' "${PATCH_SERIES_FILE}" >&2
    exit 1
  fi

  local patch_entry patch_file
  while IFS= read -r patch_entry || [[ -n "${patch_entry}" ]]; do
    patch_entry="${patch_entry%%#*}"
    patch_entry="$(printf '%s' "${patch_entry}" | xargs)"
    [[ -z "${patch_entry}" ]] && continue

    patch_file="$(dirname "${PATCH_SERIES_FILE}")/${patch_entry}"
    if [[ ! -f "${patch_file}" ]]; then
      printf 'patch listed in %s not found: %s\n' "${PATCH_SERIES_FILE}" "${patch_file}" >&2
      exit 1
    fi

    log "Applying patch ${patch_file}"
    if ! git am --3way "${patch_file}"; then
      local detail_file
      detail_file="$(mktemp)"
      {
        printf 'Patch application failed while preparing patched release branch.\n\n'
        printf -- '- upstream release tag: %s\n' "${release_tag}"
        printf -- '- upstream commit: %s\n' "${upstream_commit}"
        printf -- '- release branch: %s\n' "${release_branch}"
        printf -- '- patch series: %s\n' "${PATCH_SERIES_FILE}"
        printf -- '- failing patch file: %s\n\n' "${patch_file}"
        printf 'Conflicted files:\n'
        git diff --name-only --diff-filter=U || true
      } >"${detail_file}"
      git am --abort || true
      fail_with_issue "patch application" "${release_tag}" "${detail_file}"
    fi
  done <"${PATCH_SERIES_FILE}"

  pnpm install --frozen-lockfile
  pnpm config:schema:gen
  # Keep release validation scoped to the fork-managed patch surfaces.
  # The broader loadConfig/temp-home suites have upstream hangs on v2026.4.5
  # and are not specific to the release patch set being applied here.
  node scripts/test-projects.mjs \
    src/config/zod-schema.session-maintenance-extensions.test.ts \
    src/agents/session-write-lock.test.ts

  if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -A
    git commit --no-verify -m "chore(release-sync): refresh generated artifacts for ${release_tag}"
  fi

  if [[ "${SYNC_DRY_RUN}" == "1" ]]; then
    log "Dry run complete; not pushing branch/tag or dispatching Docker Release"
    exit 0
  fi

  git push origin "HEAD:refs/heads/${release_branch}" --force-with-lease
  git tag -f -a "${release_tag}" -m "Release ${release_tag} for Thinkscape fork with automation-managed patches"
  git push origin "refs/tags/${release_tag}" --force

  cancel_inflight_docker_release_runs
  local dispatched_at run_id
  dispatched_at="$(iso_now)"
  run_id="$(dispatch_docker_release "${release_tag}" "${dispatched_at}")"
  log "Watching Docker Release run ${run_id}"
  wait_for_run_completion "${run_id}" "${release_tag}"
  verify_published_images "${release_version}"

  log "Release ${release_tag} published successfully as ${TARGET_IMAGE}:${release_version} and :latest"
}

main "$@"
