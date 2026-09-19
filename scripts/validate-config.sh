#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

required_variables=(
  SOURCE_IMAGE
  COPY_MODE
  PLATFORM
  PUSH_TARGETS
)

for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || fail "缺少必填配置：${variable_name}"
done

[[ "$SOURCE_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]] \
  || fail "source_image 包含无效字符"
[[ "$SOURCE_IMAGE" != *://* && "$SOURCE_IMAGE" != *//* ]] \
  || fail "source_image 应填写镜像引用，不要包含 URL 协议或空路径段"

TARGET_IMAGE="${TARGET_IMAGE:-}"
if [[ -n "$TARGET_IMAGE" ]]; then
  [[ "$TARGET_IMAGE" =~ ^[a-z0-9][a-z0-9._/-]*:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] \
    || fail "target_image 必须是小写仓库路径加显式标签，例如 mirror/nginx:1.27"
  [[ "$TARGET_IMAGE" == */* ]] \
    || fail "target_image 必须包含命名空间，例如 mirror/nginx:1.27"
  [[ "$TARGET_IMAGE" != /* && "$TARGET_IMAGE" != */ && "$TARGET_IMAGE" != *//* ]] \
    || fail "target_image 的路径格式无效"

  target_repository="${TARGET_IMAGE%:*}"
  IFS='/' read -r -a target_segments <<< "$target_repository"
  for segment in "${target_segments[@]}"; do
    [[ "$segment" =~ ^[a-z0-9]+([._-]+[a-z0-9]+)*$ ]] \
      || fail "target_image 包含无效的仓库路径段：${segment}"
  done
fi

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

IFS=',' read -r -a push_targets <<< "$PUSH_TARGETS"
[[ "${#push_targets[@]}" -gt 0 ]] || fail "PUSH_TARGETS 不能为空"

registry_summary=""
for raw_name in "${push_targets[@]}"; do
  registry_name="$(trim "$raw_name" | tr '[:upper:]' '[:lower:]')"
  [[ "$registry_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || fail "PUSH_TARGETS 中的名称无效：${raw_name}"

  upper="$(printf '%s' "$registry_name" | tr '[:lower:]' '[:upper:]')"
  registry_var="${upper}_REGISTRY"
  username_var="${upper}_USERNAME"
  password_var="${upper}_PASSWORD"
  namespace_var="${upper}_NAMESPACE"

  registry="${!registry_var:-}"
  username="${!username_var:-}"
  password="${!password_var:-}"
  namespace="${!namespace_var:-}"

  [[ -n "$registry" ]] || fail "缺少必填配置：${registry_var}"
  [[ -n "$username" ]] || fail "缺少必填配置：${username_var}"
  [[ -n "$password" ]] || fail "缺少必填配置：${password_var}"

  [[ "$registry" != *://* ]] || fail "${registry_var} 只填写域名，不要包含 http:// 或 https://"
  [[ "$registry" != */* ]] || fail "${registry_var} 只填写域名，不要包含命名空间或仓库路径"
  [[ "$registry" =~ ^([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?|localhost)(:[0-9]{1,5})?$ ]] \
    || fail "${registry_var} 不是有效的 Registry 地址"

  if [[ -n "$namespace" ]]; then
    [[ "$namespace" =~ ^[a-z0-9]+([._-]+[a-z0-9]+)*$ ]] \
      || fail "${namespace_var} 不是有效的命名空间或项目名"
  elif [[ -z "$TARGET_IMAGE" ]]; then
    fail "未填写 TARGET_IMAGE 时，${registry_var} 需要同时配置 ${namespace_var}"
  fi

  if [[ -n "$registry_summary" ]]; then
    registry_summary="${registry_summary}、"
  fi
  registry_summary="${registry_summary}${registry_name}(${registry})"
done

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
if [[ -n "$TARGET_IMAGE" ]]; then
  echo "目标路径：${TARGET_IMAGE}（推送到：${registry_summary}）"
else
  echo "目标 Registry：${registry_summary}"
fi
