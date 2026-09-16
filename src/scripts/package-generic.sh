#!/usr/bin/env bash
# generic 制品：Gitea package 或 GitHub Actions artifact，查最新并下载

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "用法: package-generic.sh <serviceName> [force]" >&2
  exit 1
fi

SERVICE_NAME="$1"
export hook_service_name="$SERVICE_NAME"
FORCE=0
if [[ $# -eq 2 && ( "$2" == "force" || "$2" == "--force" ) ]]; then
  FORCE=1
fi

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/hooks.sh
source "${DEPLOY_ROOT}/lib/hooks.sh"

log_pkg() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

_fail_package() {
  export hook_package_errmsg="$1"
  run_hook on-package-fail
  log_pkg "$1"
  exit 1
}

pkg_source="$(service_package_source "$SERVICE_NAME")"
owner="$(service_package_field "$SERVICE_NAME" owner)"
pkg_name="$(service_package_field "$SERVICE_NAME" name)"
pkg_file="$(service_package_field "$SERVICE_NAME" file)"
pkg_repo="$(service_package_field "$SERVICE_NAME" repo)"

run_hook on-package-start

version=""
gitea_download_url=""
github_download_url=""

case "$pkg_source" in
  github)
    api="$(github_api_url)"
    list_url="${api}/repos/${owner}/${pkg_repo}/actions/artifacts"
    log_pkg "查询 GitHub Actions artifact 最新: ${list_url} name=${pkg_name}"
    artifacts_json="$(github_curl -G \
      --data-urlencode "name=${pkg_name}" \
      --data-urlencode "per_page=100" \
      "$list_url")" || _fail_package "获取 GitHub Actions artifact 列表失败"
    version="$(echo "$artifacts_json" | jq -r --arg n "$pkg_name" '
      [(.artifacts // [])[] | select(.expired == false and .name == $n)]
      | sort_by(.created_at)
      | reverse
      | .[0].id // empty
    ')"
    if [[ -z "$version" || "$version" == "null" ]]; then
      _fail_package "未找到未过期的 GitHub Actions artifact: ${owner}/${pkg_repo} name=${pkg_name}"
    fi
    github_download_url="${api}/repos/${owner}/${pkg_repo}/actions/artifacts/${version}/zip"
    ;;
  gitea)
    token="$(gitea_token)"
    base_url="$(gitea_url)"
    latest_url="${base_url}/api/v1/packages/${owner}/generic/${pkg_name}/-/latest"
    log_pkg "查询最新版本: ${latest_url}"
    latest_json="$(curl -sf -H "Authorization: token ${token}" "$latest_url")" || \
      _fail_package "获取 Gitea 最新版本失败"
    version="$(echo "$latest_json" | jq -r '.version // empty')"
    if [[ -z "$version" ]]; then
      _fail_package "无法从 Gitea 响应中提取 version"
    fi
    gitea_download_url="${base_url}/api/packages/${owner}/generic/${pkg_name}/${version}/${pkg_file}"
    ;;
  *)
    _fail_package "不支持的 package.source: ${pkg_source}"
    ;;
esac

current="$(versions_get "$SERVICE_NAME")"
if [[ "$FORCE" -eq 0 && "$version" == "$current" ]]; then
  log_pkg "版本未变 (${version})，跳过部署"
  run_hook on-package-skip
  echo "skip_deploy"
  exit 0
fi

if [[ "$FORCE" -eq 1 && "$version" == "$current" ]]; then
  log_pkg "配置已变更，强制重新下载版本 ${version}"
fi

temp_uuid="$(new_uuid)"
dest_dir="${TEMP_DIR}/${temp_uuid}"
mkdir -p "$dest_dir"
dest_file="${dest_dir}/${pkg_file}"

if [[ "$pkg_source" == "github" ]]; then
  log_pkg "下载制品: ${github_download_url} -> ${dest_file}"
  github_curl -o "$dest_file" "$github_download_url" || {
    rm -rf "$dest_dir"
    _fail_package "下载 GitHub Actions artifact 失败"
  }
else
  log_pkg "下载制品: ${gitea_download_url} -> ${dest_file}"
  curl -sf -H "Authorization: token ${token}" -o "$dest_file" "$gitea_download_url" || {
    rm -rf "$dest_dir"
    _fail_package "下载制品文件失败"
  }
fi

log_pkg "已下载版本 ${version}"
export hook_package_version_tag="$version"
run_hook on-package-success
echo "$version"
echo "$dest_file"
