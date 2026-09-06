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

resolve_target() {
  local source="$1"
  local explicit="${2:-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return
  fi

  local without_digest="${source%%@*}"
  if [[ "$without_digest" != *:* ]]; then
    fail "只写源镜像时必须带标签，或同时填写目标镜像：${source}"
  fi

  local path="$without_digest"
  local first="${path%%/*}"
  if [[ "$path" == */* && ("$first" == *.* || "$first" == *:* || "$first" == "localhost") ]]; then
    path="${path#*/}"
  fi

  local name="${path%:*}"
  local tag="${path##*:}"
  local repo="${name##*/}"

  [[ -n "$repo" && -n "$tag" && "$name" != "$path" ]] \
    || fail "无法从源镜像推导目标地址，请显式填写目标镜像：${source}"

  printf '%s' "${TCR_NAMESPACE}/${repo}:${tag}"
}

append_item() {
  local source="$1"
  local target="$2"
  local copy_mode="$3"
  local platform="$4"
  local escaped_source escaped_target escaped_copy_mode escaped_platform

  escaped_source="$(json_escape "$source")"
  escaped_target="$(json_escape "$target")"
  escaped_copy_mode="$(json_escape "$copy_mode")"
  escaped_platform="$(json_escape "$platform")"
  items+=("{\"source_image\":\"${escaped_source}\",\"target_image\":\"${escaped_target}\",\"copy_mode\":\"${escaped_copy_mode}\",\"platform\":\"${escaped_platform}\"}")
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

  target_image="$(resolve_target "$source_image" "$target_image")"
  append_item "$source_image" "$target_image" "$DEFAULT_COPY_MODE" "$DEFAULT_PLATFORM"
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
TCR_NAMESPACE="${TCR_NAMESPACE:-mirror}"
DEFAULT_COPY_MODE="${COPY_MODE:-all-platforms}"
DEFAULT_PLATFORM="${PLATFORM:-linux/amd64}"
BEFORE_SHA="${BEFORE_SHA:-}"
AFTER_SHA="${AFTER_SHA:-}"
items=()

case "$PLAN_MODE" in
  inputs)
    [[ -n "${SOURCE_IMAGE:-}" ]] || fail "缺少必填配置：SOURCE_IMAGE"
    [[ -n "${TARGET_IMAGE:-}" ]] || fail "缺少必填配置：TARGET_IMAGE"
    append_item "$SOURCE_IMAGE" "$TARGET_IMAGE" "$DEFAULT_COPY_MODE" "$DEFAULT_PLATFORM"
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
  target_image="${item#*\"target_image\":\"}"
  target_image="${target_image%%\"*}"
  echo "- ${source_image} -> ${target_image}"
done
