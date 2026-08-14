#!/usr/bin/env bash

# Release tags use a numeric suffix for correction releases while package.json
# keeps the base stable version, for example v2026.7.1-2 -> 2026.7.1.
thinkscape_is_supported_release_tag() {
  local release_tag="$1"
  local stable_pattern='^v[0-9]{4}\.[1-9][0-9]*\.[1-9][0-9]*(-[1-9][0-9]*)?$'
  local beta_pattern='^v[0-9]{4}\.[1-9][0-9]*\.[1-9][0-9]*-beta\.[1-9][0-9]*$'

  [[ "${release_tag}" =~ ${stable_pattern} || "${release_tag}" =~ ${beta_pattern} ]]
}

thinkscape_release_package_version() {
  local release_tag="$1"
  local version="${release_tag#v}"
  local correction_pattern='^([0-9]{4}\.[1-9][0-9]*\.[1-9][0-9]*)-[1-9][0-9]*$'

  if [[ "${version}" =~ ${correction_pattern} ]]; then
    version="${BASH_REMATCH[1]}"
  fi

  printf '%s\n' "${version}"
}

thinkscape_is_latest_release_version() {
  local version="$1"
  thinkscape_is_supported_release_tag "v${version}"
}
