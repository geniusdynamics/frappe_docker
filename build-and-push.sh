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

show_help() {
  cat <<EOF
Usage: $SCRIPT_NAME [VERSION]

Build and push ERPNext Docker images.

Arguments:
  VERSION    Optional. Specific version to build (e.g., v15.0.0, v15.1.2)
             If not provided, the script will fetch and build the latest release.

Environment Variables:
  DOCKER_USERNAME    Docker Hub username (required)
  DOCKER_PASSWORD    Docker Hub password or access token (required)

Examples:
  $SCRIPT_NAME           # Build latest release
  $SCRIPT_NAME v15.0.0   # Build specific version v15.0.0
  $SCRIPT_NAME v15.1.2   # Build specific version v15.1.2

Note: Only v15.x.x versions are supported.
EOF
}

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
  if [ -z "${DOCKER_USERNAME:-}" ]; then
    error "DOCKER_USERNAME environment variable is not set"
    exit 1
  fi

  if [ -z "${DOCKER_PASSWORD:-}" ]; then
    error "DOCKER_PASSWORD environment variable is not set"
    exit 1
  fi

  if [ ! -f "apps.json" ]; then
    error "apps.json file not found in current directory"
    exit 1
  fi

  if [ ! -f "images/layered/Containerfile" ]; then
    error "Containerfile not found at images/layered/Containerfile"
    exit 1
  fi
}

docker_login() {
  log "Logging into Docker Hub..."

  if echo "$DOCKER_PASSWORD" | docker login docker.io -u "$DOCKER_USERNAME" --password-stdin; then
    log "Successfully logged into Docker Hub"
  else
    error "Failed to login to Docker Hub"
    exit 1
  fi
}

fetch_latest_release() {
  local api_url="https://api.github.com/repos/frappe/erpnext/releases"
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

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

  local latest_v15_release
  if ! latest_v15_release=$(echo "$releases" | jq '.[] | select(.tag_name | startswith("v15."))' | jq -s '.[0]'); then
    error "Failed to find latest v15 release"
    exit 1
  fi

  if [ -z "$latest_v15_release" ] || [ "$latest_v15_release" = "null" ]; then
    error "No v15 releases found"
    exit 1
  fi

  local latest_tag
  if ! latest_tag=$(echo "$latest_v15_release" | jq -r '.tag_name'); then
    error "Failed to extract tag name from release"
    exit 1
  fi

  if [ -z "$latest_tag" ] || [ "$latest_tag" = "null" ]; then
    error "Invalid tag name received: $latest_tag"
    exit 1
  fi

  local release_date
  if ! release_date=$(echo "$latest_v15_release" | jq -r '.created_at'); then
    error "Failed to extract release date"
    exit 1
  fi

  echo "$latest_tag|$release_date"
}

validate_version() {
  local tag="$1"

  if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
    error "Invalid version format: $tag (expected v{major}.{minor}.{patch} or v{major}.{minor}.{patch}-{suffix})"
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
    "docker.io/geniusdynamics/erpnext:$image_version"
    "docker.io/geniusdynamics/erpnext:latest"
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

docker_logout() {
  log "Logging out from Docker Hub..."
  docker logout docker.io 2>/dev/null || true
}

main() {
  case "${1:-}" in
  -h | --help)
    show_help
    exit 0
    ;;
  esac

  local target_version="${1:-}"

  log "Starting ERPNext Docker build and push process"

  check_dependencies
  validate_environment
  docker_login

  local latest_tag
  local release_date

  if [ -n "$target_version" ]; then
    log "Using specified version: $target_version"
    latest_tag="$target_version"
    release_date="user-specified"
  else
    log "Fetching latest ERPNext release from GitHub API..."
    local release_info
    if ! release_info=$(fetch_latest_release); then
      docker_logout
      exit 1
    fi
    IFS='|' read -r latest_tag release_date <<<"$release_info"
    log "Fetched latest version: $latest_tag"
    log "Release created at: $release_date"
  fi

  validate_version "$latest_tag"

  local version_tags
  if ! version_tags=$(build_version_tags "$latest_tag"); then
    docker_logout
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
    docker_logout
    exit 1
  fi

  build_docker_image "$frappe_branch" "$apps_json_base64"
  tag_and_push_images "$image_version"

  log "Cleaning up local images..."
  docker rmi "erp-next:$image_version" 2>/dev/null || true
  docker rmi "docker.io/geniusdynamics/erpnext:$image_version" 2>/dev/null || true
  docker rmi "docker.io/geniusdynamics/erpnext:latest" 2>/dev/null || true

  # docker_logout

  log "Successfully built and pushed ERPNext Docker images"
  log "Images: docker.io/geniusdynamics/erpnext:$image_version, docker.io/geniusdynamics/erpnext:latest"
}

main "$@"
