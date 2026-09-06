#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

required_variables=(
  SOURCE_IMAGE
  TARGET_IMAGE
  COPY_MODE
  PLATFORM
  TCR_REGISTRY
  TCR_USERNAME
  TCR_PASSWORD
)

for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || fail "缺少必填配置：${variable_name}"
done

[[ "$TCR_REGISTRY" != *://* ]] || fail "TCR_REGISTRY 只填写域名，不要包含 http:// 或 https://"
[[ "$TCR_REGISTRY" != */* ]] || fail "TCR_REGISTRY 只填写域名，不要包含命名空间或仓库路径"
[[ "$TCR_REGISTRY" =~ ^([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?|localhost)(:[0-9]{1,5})?$ ]] \
  || fail "TCR_REGISTRY 不是有效的 Registry 地址"

[[ "$SOURCE_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]] \
  || fail "source_image 包含无效字符"
[[ "$SOURCE_IMAGE" != *://* && "$SOURCE_IMAGE" != *//* ]] \
  || fail "source_image 应填写镜像引用，不要包含 URL 协议或空路径段"
[[ "$TARGET_IMAGE" =~ ^[a-z0-9][a-z0-9._/-]*:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] \
  || fail "target_image 必须是小写仓库路径加显式标签，例如 mirror/nginx:1.27"
[[ "$TARGET_IMAGE" == */* ]] \
  || fail "target_image 必须包含 TCR 命名空间，例如 mirror/nginx:1.27"
[[ "$TARGET_IMAGE" != /* && "$TARGET_IMAGE" != */ && "$TARGET_IMAGE" != *//* ]] \
  || fail "target_image 的路径格式无效"

target_repository="${TARGET_IMAGE%:*}"
IFS='/' read -r -a target_segments <<< "$target_repository"
for segment in "${target_segments[@]}"; do
  [[ "$segment" =~ ^[a-z0-9]+([._-]+[a-z0-9]+)*$ ]] \
    || fail "target_image 包含无效的仓库路径段：${segment}"
done

case "$COPY_MODE" in
  all-platforms)
    ;;
  single-platform)
    [[ "$PLATFORM" =~ ^[a-z0-9]+/[a-z0-9_]+(/[a-z0-9._-]+)?$ ]] \
      || fail "platform 格式无效，应类似 linux/amd64 或 linux/arm/v7"
    ;;
  *)
    fail "copy_mode 只能是 all-platforms 或 single-platform"
    ;;
esac

if [[ -n "${SOURCE_USERNAME:-}" || -n "${SOURCE_PASSWORD:-}" ]]; then
  [[ -n "${SOURCE_USERNAME:-}" && -n "${SOURCE_PASSWORD:-}" ]] \
    || fail "私有源仓库必须同时配置 SOURCE_USERNAME 和 SOURCE_PASSWORD"
fi

first_component="${SOURCE_IMAGE%%/*}"
if [[ "$SOURCE_IMAGE" == */* && ("$first_component" == *.* || "$first_component" == *:* || "$first_component" == "localhost") ]]; then
  source_registry="$first_component"
else
  source_registry="docker.io"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'source_registry=%s\n' "$source_registry" >> "$GITHUB_OUTPUT"
fi

echo "配置检查通过"
echo "源 Registry：$source_registry"
echo "目标镜像：${TCR_REGISTRY}/${TARGET_IMAGE}"
