#!/usr/bin/env bash
# Resolve PrivateAgent iOS marketing version + encoded build number.
# Never prints secrets. Safe to run on Linux.
#
# Usage:
#   Scripts/resolve-ios-release-version.sh --tag v1.2.3
#   Scripts/resolve-ios-release-version.sh --ci
#
# CI env:
#   EVENT_NAME, REF, REF_NAME, INPUT_TAG, GITHUB_RUN_NUMBER
#   GITHUB_OUTPUT (optional) — also write GitHub Actions outputs
set -euo pipefail

usage() {
  echo "Usage: $0 --tag vMAJOR.MINOR.PATCH | --ci"
}

is_release=false
tag=""
mode=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      mode="tag"
      tag="${2:-}"
      shift 2
      ;;
    --ci)
      mode="ci"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "::error::Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$mode" ]]; then
  usage
  exit 1
fi

if [[ "$mode" == "ci" ]]; then
  event="${EVENT_NAME:-}"
  ref="${REF:-}"
  ref_name="${REF_NAME:-}"
  input_tag="${INPUT_TAG:-}"

  if [[ "$event" == "workflow_dispatch" ]]; then
    is_release=true
    tag="$input_tag"
  elif [[ "$ref" == refs/tags/* ]]; then
    is_release=true
    tag="$ref_name"
  else
    is_release=false
    tag=""
  fi
fi

marketing_version="0.0.0"
# Non-release CI builds use the workflow run number so each compile is unique.
# Release builds replace this with the encoded semver below.
build_number="${GITHUB_RUN_NUMBER:-0}"

if [[ "$is_release" == true || "$mode" == "tag" ]]; then
  if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "::error::Release tag must be vMAJOR.MINOR.PATCH (example: v1.2.3). Got '${tag:-<empty>}'."
    echo "Create a tag with: git tag v1.0.0 && git push origin v1.0.0"
    echo "Do not use a branch name. Manual dispatch must re-run an existing tag."
    exit 1
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"

  if (( 10#$major > 2000 || 10#$minor > 999 || 10#$patch > 999 )); then
    echo "::error::Version $tag is too large for the encoded build number (major<=2000, minor<=999, patch<=999)."
    exit 1
  fi

  is_release=true
  marketing_version="${major}.${minor}.${patch}"
  # Deterministic and monotonically increasing as versions increase:
  # v1.2.3 -> 1002003. The same tag always produces the same CFBundleVersion,
  # so a tag cannot ship two different binaries to TestFlight.
  build_number=$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))
fi

summary="is_release=${is_release}
tag=${tag}
marketing_version=${marketing_version}
build_number=${build_number}"
printf '%s\n' "$summary"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf '%s\n' "$summary" >> "$GITHUB_OUTPUT"
fi
