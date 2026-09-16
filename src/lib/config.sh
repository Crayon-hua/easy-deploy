#!/usr/bin/env bash
# 读取 easy-deploy-config.yaml 与 Gitea / GitHub 相关配置

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"

if ! resolve_yq_bin; then
  die "未找到 mikefarah/yq（Go 版）。请重新运行 install.sh，勿使用 apt 的 Python 版 yq"
fi

cfg() {
  "$YQ_BIN" eval "$1" "$CONFIG_FILE"
}

cfg_raw() {
  "$YQ_BIN" eval -r "$1" "$CONFIG_FILE"
}

cfg_is_empty() {
  local v="${1:-}"
  [[ -z "$v" || "$v" == "null" ]]
}

resolve_token() {
  local raw="${1:-}"
  local label="${2:-token}"
  if cfg_is_empty "$raw"; then
    printf '%s' ""
    return 0
  fi
  if [[ "$raw" =~ ^\$\{([^}]+)\}$ ]]; then
    local var_name="${BASH_REMATCH[1]}"
    local value="${!var_name:-}"
    if [[ -z "$value" ]]; then
      die "环境变量 ${var_name} 未设置（${label} 需要）"
    fi
    printf '%s' "$value"
  else
    printf '%s' "$raw"
  fi
}

gitea_token() {
  resolve_token "$(cfg_raw '.gitea.token')" "gitea.token"
}

gitea_url() {
  local url
  url="$(cfg_raw '.gitea.url')"
  if cfg_is_empty "$url"; then
    printf '%s' ""
    return 0
  fi
  printf '%s' "$url"
}

gitea_configured() {
  local url raw_token
  url="$(cfg_raw '.gitea.url')"
  raw_token="$(cfg_raw '.gitea.token')"
  ! cfg_is_empty "$url" || ! cfg_is_empty "$raw_token"
}

gitea_host() {
  local url
  url="$(gitea_url)"
  url="${url#http://}"
  url="${url#https://}"
  printf '%s' "$url"
}

github_token() {
  resolve_token "$(cfg_raw '.github.token')" "github.token"
}

github_configured() {
  local raw_token
  raw_token="$(cfg_raw '.github.token')"
  ! cfg_is_empty "$raw_token"
}

github_api_url() {
  local url
  url="$(cfg_raw '.github.url')"
  if cfg_is_empty "$url"; then
    printf '%s' "https://api.github.com"
    return 0
  fi
  printf '%s' "${url%/}"
}

github_api_version() {
  printf '%s' "2022-11-28"
}

github_registry() {
  local reg
  reg="$(cfg_raw '.github.registry')"
  if cfg_is_empty "$reg"; then
    printf '%s' "ghcr.io"
    return 0
  fi
  printf '%s' "$reg"
}

# docker login 用户名：github.username，未配则用 package.owner（组织镜像请显式配 PAT 所属用户）
github_docker_user() {
  local user
  user="$(cfg_raw '.github.username')"
  if cfg_is_empty "$user"; then
    printf '%s' "$1"
    return 0
  fi
  printf '%s' "$user"
}

github_curl() {
  local token
  token="$(github_token)"
  curl -sfSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: $(github_api_version)" \
    "$@"
}

service_count() {
  cfg '.services | length'
}

service_name_at() {
  cfg_raw ".services[$1].name"
}

service_names() {
  local count i
  count="$(service_count)"
  for ((i = 0; i < count; i++)); do
    service_name_at "$i"
  done
}

service_package_type() {
  cfg_raw ".services[] | select(.name == \"$1\") | .package.type"
}

service_deploy_strategy() {
  cfg_raw ".services[] | select(.name == \"$1\") | .deploy.strategy"
}

service_package_field() {
  local name="$1" field="$2"
  cfg_raw ".services[] | select(.name == \"$1\") | .package.${field}"
}

# 省略时默认 gitea；GitHub 制品须显式 source: github
service_package_source() {
  local raw
  raw="$(service_package_field "$1" source)"
  if cfg_is_empty "$raw"; then
    printf '%s' "gitea"
    return 0
  fi
  printf '%s' "$raw"
}

package_image_host() {
  local source
  source="$(service_package_source "$1")"
  if [[ "$source" == "github" ]]; then
    github_registry
  else
    gitea_host
  fi
}

service_deploy_field() {
  local name="$1" field="$2"
  cfg_raw ".services[] | select(.name == \"$1\") | .deploy.${field}"
}

reload_nginx_cmd() {
  cfg_raw '.scripts."reload-nginx-cmd"'
}

_positive_int_or_default() {
  local raw="$1" default="$2"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$default"
}

package_timeout_seconds() {
  _positive_int_or_default "$(cfg_raw '.scripts."package-timeout-seconds"')" "60"
}

max_log_history() {
  cfg_raw '.logs."max-log-history"'
}

log_level() {
  local level
  level="$(cfg_raw '.logs.level')"
  if [[ -z "$level" || "$level" == "null" ]]; then
    printf '%s' "deploy"
  else
    printf '%s' "$level"
  fi
}

hook_cmd() {
  cfg_raw ".hooks.\"$1\""
}
