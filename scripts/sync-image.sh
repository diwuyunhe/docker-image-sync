#!/usr/bin/env bash
set -Eeuo pipefail

PUSH_TARGETS="${PUSH_TARGETS:-harbor,tcr}"

target_names=()
target_refs=()
heartbeat_pid=""

fail() {
  echo "::error::$*" >&2
  exit 1
}

stop_heartbeat() {
  if [[ -n "${heartbeat_pid}" ]]; then
    kill "${heartbeat_pid}" 2>/dev/null || true
    wait "${heartbeat_pid}" 2>/dev/null || true
    heartbeat_pid=""
  fi
}

start_heartbeat() {
  (
    while true; do
      sleep 30
      echo "仍在同步，已等待 ${SECONDS}s：${SOURCE_IMAGE} -> ${target_refs[*]}"
    done
  ) &
  heartbeat_pid="$!"
}

build_target_ref() {
  local registry="$1"
  local namespace="$2"

  if [[ -n "${TARGET_IMAGE:-}" ]]; then
    printf '%s/%s' "$registry" "$TARGET_IMAGE"
    return 0
  fi

  [[ -n "${REPO_TAG:-}" ]] || return 1
  if [[ -n "$namespace" ]]; then
    printf '%s/%s/%s' "$registry" "$namespace" "$REPO_TAG"
  else
    printf '%s/%s' "$registry" "$REPO_TAG"
  fi
}

trap 'stop_heartbeat' EXIT

IFS=',' read -r -a push_targets <<< "$PUSH_TARGETS"
for raw_name in "${push_targets[@]}"; do
  name="$(printf '%s' "$raw_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$name" ]] || continue
  upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"

  registry_var="${upper}_REGISTRY"
  namespace_var="${upper}_NAMESPACE"
  registry="${!registry_var:-}"
  namespace="${!namespace_var:-}"

  [[ -n "$registry" ]] || fail "缺少必填配置：${registry_var}"
  ref="$(build_target_ref "$registry" "$namespace")" \
    || fail "无法为目标 Registry「${name}」生成镜像地址，请检查 TARGET_IMAGE 或 REPO_TAG"

  target_names+=("$name")
  target_refs+=("$ref")
done

[[ "${#target_refs[@]}" -gt 0 ]] || fail "PUSH_TARGETS 未配置任何有效的目标 Registry"

echo "开始同步：${SOURCE_IMAGE}"
echo "同步模式：${COPY_MODE}"
for index in "${!target_refs[@]}"; do
  echo "目标 Registry ${target_names[$index]}：${target_refs[$index]}"
done

case "$COPY_MODE" in
  all-platforms)
    command -v regctl >/dev/null 2>&1 || {
      echo "缺少 regctl，完整多平台同步无法继续" >&2
      exit 1
    }
    echo "正在用 regctl 复制多架构镜像；海外运行器推送到国内 Registry 可能需要较长时间"
    start_heartbeat
    for ref in "${target_refs[@]}"; do
      regctl -v info image copy "$SOURCE_IMAGE" "$ref"
    done
    ;;
  single-platform)
    echo "正在同步单个平台：${PLATFORM}"
    start_heartbeat
    docker pull --platform "$PLATFORM" "$SOURCE_IMAGE"
    for ref in "${target_refs[@]}"; do
      docker tag "$SOURCE_IMAGE" "$ref"
      docker push "$ref"
    done
    ;;
  *)
    echo "未知的同步模式：$COPY_MODE" >&2
    exit 1
    ;;
esac

stop_heartbeat

declare -a digests=()
for ref in "${target_refs[@]}"; do
  inspect_output="$(docker buildx imagetools inspect "$ref")"
  printf '%s\n' "$inspect_output"
  digest="$(awk '/^Digest:/ { print $2; exit }' <<< "$inspect_output")"
  digests+=("$digest")
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'target_ref=%s\n' "${target_refs[0]}" >> "$GITHUB_OUTPUT"
  printf 'digest=%s\n' "${digests[0]:-}" >> "$GITHUB_OUTPUT"
  for index in "${!target_refs[@]}"; do
    printf '%s_target_ref=%s\n' "${target_names[$index]}" "${target_refs[$index]}" >> "$GITHUB_OUTPUT"
    printf '%s_digest=%s\n' "${target_names[$index]}" "${digests[$index]:-}" >> "$GITHUB_OUTPUT"
  done
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## 镜像同步成功"
    echo
    echo "| 项目 | 内容 |"
    echo "| --- | --- |"
    echo "| 源镜像 | \`${SOURCE_IMAGE}\` |"
    echo "| 同步模式 | \`${COPY_MODE}\` |"
    if [[ "$COPY_MODE" == "single-platform" ]]; then
      echo "| 平台 | \`${PLATFORM}\` |"
    fi
    echo "| 目标 Registry | \`${PUSH_TARGETS}\` |"
    echo
    echo "| 目标 Registry | 目标镜像 | Digest |"
    echo "| --- | --- | --- |"
    for index in "${!target_refs[@]}"; do
      echo "| \`${target_names[$index]}\` | \`${target_refs[$index]}\` | \`${digests[$index]:-未返回}\` |"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi

for index in "${!target_refs[@]}"; do
  echo "镜像同步完成：${target_refs[$index]}${digests[$index]:+@${digests[$index]}}"
done
