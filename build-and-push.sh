#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_PREFIX="[$SCRIPT_NAME]"

log() {
  echo "${LOG_PREFIX} $*"
}

error() {
  echo "${LOG_PREFIX} ERROR: $*" >&2
}

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    error "Script failed with exit code $exit_code"
  fi
}

trap cleanup EXIT

check_dependencies() {
  local missing_deps=()

  for cmd in curl jq docker base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_deps+=("$cmd")
    fi
  done

  if [ ${#missing_deps[@]} -gt 0 ]; then
    error "Missing required dependencies: ${missing_deps[*]}"
    error "Please install the missing tools and try again."
    exit 1
  fi
}

validate_environment() {

  if [ ! -f "apps.json" ]; then
    error "apps.json file not found in current directory"
    exit 1
  fi

  if [ ! -f "images/layered/Containerfile" ]; then
    error "Containerfile not found at images/layered/Containerfile"
    exit 1
  fi
}

fetch_latest_release() {
  local api_url="https://api.github.com/repos/frappe/erpnext/releases"
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  log "Fetching latest ERPNext release from GitHub API..."

  local releases
  if ! releases=$(curl -fsSL "${headers[@]}" "$api_url"); then
    error "Failed to fetch releases from GitHub API"
    exit 1
  fi

  local release_count
  if ! release_count=$(echo "$releases" | jq length 2>/dev/null); then
    error "Invalid JSON response from GitHub API"
    exit 1
  fi

  if [ "$release_count" -eq 0 ]; then
    error "No releases found"
    exit 1
  fi

  local latest_release
  if ! latest_release=$(echo "$releases" | jq '.[0]'); then
    error "Failed to parse latest release"
    exit 1
  fi

  local latest_tag
  if ! latest_tag=$(echo "$latest_release" | jq -r '.tag_name'); then
    error "Failed to extract tag name from release"
    exit 1
  fi

  if [ -z "$latest_tag" ] || [ "$latest_tag" = "null" ]; then
    error "Invalid tag name received: $latest_tag"
    exit 1
  fi

  local release_date
  if ! release_date=$(echo "$latest_release" | jq -r '.created_at'); then
    error "Failed to extract release date"
    exit 1
  fi

  echo "$latest_tag|$release_date"
}

validate_version() {
  local tag="$1"
  local allowed_version="${1:-v15}"

  if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid version format: $tag (expected v{major}.{minor}.{patch})"
    exit 1
  fi

  local major_version
  major_version=$(echo "$tag" | cut -d. -f1 | sed 's/v//')

  if [ "$major_version" != "15" ]; then
    log "Skipping build: Only v15 releases are allowed (found: $tag)"
    exit 0
  fi
}

build_version_tags() {
  local tag="$1"

  local erpnext_version="$tag"
  local frappe_branch="version-$(echo "$tag" | cut -d. -f1 | sed 's/v//')"
  local image_version="$(echo "$tag" | sed 's/v//')"

  if [ -z "$image_version" ]; then
    error "Failed to extract image version from tag: $tag"
    exit 1
  fi

  echo "$erpnext_version|$frappe_branch|$image_version"
}

build_docker_image() {
  local frappe_branch="$1"
  local apps_json_base64="$2"

  log "Building Docker image with Frappe branch: $frappe_branch"

  local build_args=(
    "--build-arg=FRAPPE_PATH=https://github.com/frappe/frappe"
    "--build-arg=FRAPPE_BRANCH=$frappe_branch"
    "--build-arg=APPS_JSON_BASE64=$apps_json_base64"
    "--tag=erp-next:$image_version"
    "--file=images/layered/Containerfile"
    "."
  )

  if ! docker build "${build_args[@]}"; then
    error "Docker build failed"
    exit 1
  fi

  log "Docker image built successfully"
}

tag_and_push_images() {
  local image_version="$1"

  local tags=(
    "geniusdynamics/erpnext:$image_version"
    "geniusdynamics/erpnext:latest"
  )

  log "Tagging and pushing Docker images..."

  for tag in "${tags[@]}"; do
    log "Tagging image as: $tag"
    if ! docker tag "erp-next:$image_version" "$tag"; then
      error "Failed to tag image as: $tag"
      exit 1
    fi

    log "Pushing image: $tag"
    if ! docker push "$tag"; then
      error "Failed to push image: $tag"
      exit 1
    fi

    log "Successfully pushed: $tag"
  done
}

main() {
  log "Starting ERPNext Docker build and push process"

  check_dependencies
  validate_environment

  local release_info
  if ! release_info=$(fetch_latest_release); then
    exit 1
  fi

  local latest_tag
  local release_date
  IFS='|' read -r latest_tag release_date <<<"$release_info"

  log "Fetched latest version: $latest_tag"
  log "Release created at: $release_date"

  validate_version "$latest_tag"

  local version_tags
  if ! version_tags=$(build_version_tags "$latest_tag"); then
    exit 1
  fi

  local erpnext_version
  local frappe_branch
  local image_version
  IFS='|' read -r erpnext_version frappe_branch image_version <<<"$version_tags"

  log "Version configuration:"
  log "  ERPNext version: $erpnext_version"
  log "  Frappe branch: $frappe_branch"
  log "  Image version: $image_version"

  local apps_json_base64
  if ! apps_json_base64=$(base64 -w 0 apps.json); then
    error "Failed to encode apps.json"
    exit 1
  fi

  build_docker_image "$frappe_branch" "$apps_json_base64"
  tag_and_push_images "$image_version"

  log "Cleaning up local images..."
  docker rmi "erp-next:$image_version" 2>/dev/null || true
  docker rmi "geniusdynamics/erpnext:$image_version" 2>/dev/null || true
  docker rmi "geniusdynamics/erpnext:latest" 2>/dev/null || true

  log "Successfully built and pushed ERPNext Docker images"
  log "Images: geniusdynamics/erpnext:$image_version, geniusdynamics/erpnext:latest"
}

main "$@"
