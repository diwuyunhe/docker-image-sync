#!/usr/bin/env bash
set -Eeuo pipefail

target_ref="${TCR_REGISTRY}/${TARGET_IMAGE}"
heartbeat_pid=""

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
      echo "仍在同步，已等待 ${SECONDS}s：${SOURCE_IMAGE} -> ${target_ref}"
    done
  ) &
  heartbeat_pid="$!"
}

trap 'stop_heartbeat' EXIT

echo "开始同步：${SOURCE_IMAGE} -> ${target_ref}"
echo "同步模式：${COPY_MODE}"

case "$COPY_MODE" in
  all-platforms)
    command -v regctl >/dev/null 2>&1 || {
      echo "缺少 regctl，完整多平台同步无法继续" >&2
      exit 1
    }
    echo "正在用 regctl 复制多架构镜像；海外运行器推送到腾讯云可能需要较长时间"
    start_heartbeat
    regctl -v info image copy "$SOURCE_IMAGE" "$target_ref"
    ;;
  single-platform)
    echo "正在同步单个平台：${PLATFORM}"
    start_heartbeat
    docker pull --platform "$PLATFORM" "$SOURCE_IMAGE"
    docker tag "$SOURCE_IMAGE" "$target_ref"
    docker push "$target_ref"
    ;;
  *)
    echo "未知的同步模式：$COPY_MODE" >&2
    exit 1
    ;;
esac

stop_heartbeat

inspect_output="$(docker buildx imagetools inspect "$target_ref")"
printf '%s\n' "$inspect_output"
digest="$(awk '/^Digest:/ { print $2; exit }' <<< "$inspect_output")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'target_ref=%s\n' "$target_ref" >> "$GITHUB_OUTPUT"
  printf 'digest=%s\n' "$digest" >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## 镜像同步成功"
    echo
    echo "| 项目 | 内容 |"
    echo "| --- | --- |"
    echo "| 源镜像 | \`${SOURCE_IMAGE}\` |"
    echo "| 目标镜像 | \`${target_ref}\` |"
    echo "| 同步模式 | \`${COPY_MODE}\` |"
    if [[ "$COPY_MODE" == "single-platform" ]]; then
      echo "| 平台 | \`${PLATFORM}\` |"
    fi
    echo "| Digest | \`${digest:-未返回}\` |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "镜像同步完成：${target_ref}${digest:+@${digest}}"
