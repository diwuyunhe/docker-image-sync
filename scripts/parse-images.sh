#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_zero_sha() {
  [[ -z "$1" || "$1" =~ ^0+$ ]]
}

# 去掉可能的 Registry 域名，返回 registry 内的仓库路径。
strip_registry() {
  local path="$1"
  local first="${path%%/*}"
  if [[ "$path" == */* && ("$first" == *.* || "$first" == *:* || "$first" == "localhost") ]]; then
    path="${path#*/}"
  fi
  printf '%s' "$path"
}

# 从 namespace/repo:tag 或 repo:tag 中取出 repo:tag。
repo_tag_of() {
  local ref="$1"
  local name="${ref%:*}"
  local tag="${ref##*:}"
  [[ "$ref" == *:* && -n "$name" && -n "$tag" && "$name" != "$ref" ]] || return 1
  printf '%s:%s' "${name##*/}" "$tag"
}

# 计算矩阵中使用的 repo:tag，用于并发分组与日志展示。
resolve_repo_tag() {
  local source="$1"
  local target="$2"
  local candidate
  if [[ -n "$target" ]]; then
    candidate="$(strip_registry "${target%%@*}")"
    repo_tag_of "$candidate" \
      || fail "无法解析目标镜像的仓库和标签：${target}"
  else
    [[ "$source" != *@* ]] \
      || fail "使用 digest 的源镜像必须同时填写目标镜像：${source}"
    candidate="$(strip_registry "$source")"
    repo_tag_of "$candidate" \
      || fail "只写源镜像时必须带标签，或同时填写目标镜像：${source}"
  fi
}

append_item() {
  local source="$1"
  local target="$2"
  local repo_tag="$3"
  local copy_mode="$4"
  local platform="$5"

  items+=("{\"source_image\":\"$(json_escape "$source")\",\"target_image\":\"$(json_escape "$target")\",\"repo_tag\":\"$(json_escape "$repo_tag")\",\"copy_mode\":\"$(json_escape "$copy_mode")\",\"platform\":\"$(json_escape "$platform")\"}")
}

parse_line() {
  local raw="$1"
  local line source_image target_image extra

  raw="${raw//$'\r'/}"
  line="$(trim "${raw%%#*}")"
  [[ -n "$line" ]] || return 0

  read -r source_image target_image extra <<< "$line"
  [[ -z "$extra" ]] || fail "每行最多填写「源镜像」或「源镜像 目标镜像」：${line}"
  [[ -n "$source_image" ]] || return 0

  local repo_tag
  repo_tag="$(resolve_repo_tag "$source_image" "$target_image")"
  append_item "$source_image" "$target_image" "$repo_tag" "$DEFAULT_COPY_MODE" "$DEFAULT_PLATFORM"
}

collect_changed_lines() {
  local before_sha="$1"
  local after_sha="$2"

  if is_zero_sha "$before_sha"; then
    cat "$IMAGES_FILE"
    return
  fi

  git rev-parse --verify --quiet "${before_sha}^{commit}" >/dev/null \
    || fail "找不到对比提交 ${before_sha}，无法判断 images.txt 的变更"
  git diff --unified=0 "$before_sha" "$after_sha" -- "$IMAGES_FILE" \
    | awk '/^\+[^+]/ { sub(/^\+/, ""); print }'
}

IMAGES_FILE="${IMAGES_FILE:-images.txt}"
PLAN_MODE="${PLAN_MODE:-file}"
DEFAULT_COPY_MODE="${COPY_MODE:-all-platforms}"
DEFAULT_PLATFORM="${PLATFORM:-linux/amd64}"
BEFORE_SHA="${BEFORE_SHA:-}"
AFTER_SHA="${AFTER_SHA:-}"
items=()

case "$PLAN_MODE" in
  inputs)
    [[ -n "${SOURCE_IMAGE:-}" ]] || fail "缺少必填配置：SOURCE_IMAGE"
    repo_tag="$(resolve_repo_tag "$SOURCE_IMAGE" "${TARGET_IMAGE:-}")"
    append_item "$SOURCE_IMAGE" "${TARGET_IMAGE:-}" "$repo_tag" "$DEFAULT_COPY_MODE" "$DEFAULT_PLATFORM"
    ;;
  file)
    [[ -f "$IMAGES_FILE" ]] || fail "找不到镜像清单：${IMAGES_FILE}"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      parse_line "$raw"
    done < "$IMAGES_FILE"
    ;;
  changed)
    [[ -f "$IMAGES_FILE" ]] || fail "找不到镜像清单：${IMAGES_FILE}"
    [[ -n "$AFTER_SHA" ]] || fail "缺少必填配置：AFTER_SHA"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      parse_line "$raw"
    done < <(collect_changed_lines "$BEFORE_SHA" "$AFTER_SHA")
    ;;
  *)
    fail "PLAN_MODE 只能是 inputs、file 或 changed"
    ;;
esac

count="${#items[@]}"
if [[ "$count" -eq 0 ]]; then
  matrix='{"include":[]}'
else
  matrix="{\"include\":[$(IFS=','; printf '%s' "${items[*]}")]}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'matrix=%s\n' "$matrix" >> "$GITHUB_OUTPUT"
  printf 'count=%s\n' "$count" >> "$GITHUB_OUTPUT"
fi

echo "待同步镜像数量：${count}"
if [[ "$count" -eq 0 ]]; then
  echo "没有需要同步的镜像"
  exit 0
fi

for item in "${items[@]}"; do
  source_image="${item#*\"source_image\":\"}"
  source_image="${source_image%%\"*}"
  repo_tag="${item#*\"repo_tag\":\"}"
  repo_tag="${repo_tag%%\"*}"
  target_image="${item#*\"target_image\":\"}"
  target_image="${target_image%%\"*}"
  if [[ -n "$target_image" ]]; then
    echo "- ${source_image} -> ${target_image}（推送到所有目标 Registry）"
  else
    echo "- ${source_image} -> <目标 Registry 命名空间>/${repo_tag}"
  fi
done
