#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d "$project_dir/.test-tmp.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "${file} 中缺少：${expected}"
}

export SOURCE_IMAGE="nginx:1.27"
export TARGET_IMAGE="mirror/nginx:1.27"
export REPO_TAG="nginx:1.27"
export COPY_MODE="all-platforms"
export PLATFORM="linux/amd64"
export PUSH_TARGETS="selfregistry,tcr"
export SELFREGISTRY_REGISTRY="registry.internal.example.com"
export SELFREGISTRY_NAMESPACE="library"
export SELFREGISTRY_USERNAME="selfregistry-user"
export SELFREGISTRY_PASSWORD="selfregistry-password"
export TCR_REGISTRY="demo.tencentcloudcr.com"
export TCR_NAMESPACE="mirror"
export TCR_USERNAME="test-user"
export TCR_PASSWORD="test-password"
export SOURCE_USERNAME=""
export SOURCE_PASSWORD=""
export GITHUB_OUTPUT="$temp_dir/validate-output"

cat > "$temp_dir/images.txt" <<'EOF'
# comment
nginx:1.27
ghcr.io/example/app:v1  team/app:v1

bitnami/redis:7.2
EOF

PLAN_MODE="file" IMAGES_FILE="$temp_dir/images.txt" GITHUB_OUTPUT="$temp_dir/parse-file" \
  "$project_dir/scripts/parse-images.sh" >/dev/null
assert_contains "$temp_dir/parse-file" 'count=3'
assert_contains "$temp_dir/parse-file" '"source_image":"nginx:1.27","target_image":"","repo_tag":"nginx:1.27"'
assert_contains "$temp_dir/parse-file" '"source_image":"ghcr.io/example/app:v1","target_image":"team/app:v1","repo_tag":"app:v1"'
assert_contains "$temp_dir/parse-file" '"source_image":"bitnami/redis:7.2","target_image":"","repo_tag":"redis:7.2"'

printf '%s\n' "# only comments" "" > "$temp_dir/empty-images.txt"
PLAN_MODE="file" IMAGES_FILE="$temp_dir/empty-images.txt" GITHUB_OUTPUT="$temp_dir/parse-empty" \
  "$project_dir/scripts/parse-images.sh" >/dev/null
assert_contains "$temp_dir/parse-empty" 'count=0'
assert_contains "$temp_dir/parse-empty" 'matrix={"include":[]}'

PLAN_MODE="inputs" GITHUB_OUTPUT="$temp_dir/parse-inputs" \
  "$project_dir/scripts/parse-images.sh" >/dev/null
assert_contains "$temp_dir/parse-inputs" 'count=1'
assert_contains "$temp_dir/parse-inputs" '"source_image":"nginx:1.27","target_image":"mirror/nginx:1.27","repo_tag":"nginx:1.27"'

TARGET_IMAGE="" PLAN_MODE="inputs" GITHUB_OUTPUT="$temp_dir/parse-inputs-derived" \
  "$project_dir/scripts/parse-images.sh" >/dev/null
assert_contains "$temp_dir/parse-inputs-derived" '"source_image":"nginx:1.27","target_image":"","repo_tag":"nginx:1.27"'

if TARGET_IMAGE="" SOURCE_IMAGE="nginx@sha256:0123abcd" PLAN_MODE="inputs" \
  GITHUB_OUTPUT="$temp_dir/parse-digest" "$project_dir/scripts/parse-images.sh" >/dev/null 2>&1; then
  fail "使用 digest 且未填目标镜像的输入未被拒绝"
fi

printf '%s\n' "nginx:1.27 extra leftover" > "$temp_dir/bad-images.txt"
if PLAN_MODE="file" IMAGES_FILE="$temp_dir/bad-images.txt" GITHUB_OUTPUT="$temp_dir/parse-bad" \
  "$project_dir/scripts/parse-images.sh" >/dev/null 2>&1; then
  fail "多余字段的镜像行未被拒绝"
fi

git_repo="$temp_dir/git-repo"
mkdir -p "$git_repo"
mkdir -p "$temp_dir/empty-git-template"
git -C "$git_repo" init --template="$temp_dir/empty-git-template" -b main >/dev/null
git -C "$git_repo" config user.email "test@example.com"
git -C "$git_repo" config user.name "test"
printf '%s\n' "nginx:1.26" > "$git_repo/images.txt"
git -C "$git_repo" add images.txt
git -C "$git_repo" commit -m "init" >/dev/null
printf '%s\n' "nginx:1.26" "redis:7" > "$git_repo/images.txt"
git -C "$git_repo" add images.txt
git -C "$git_repo" commit -m "add redis" >/dev/null
before_sha="$(git -C "$git_repo" rev-parse HEAD^)"
after_sha="$(git -C "$git_repo" rev-parse HEAD)"
(
  cd "$git_repo"
  PLAN_MODE="changed" IMAGES_FILE="images.txt" BEFORE_SHA="$before_sha" AFTER_SHA="$after_sha" \
    GITHUB_OUTPUT="$temp_dir/parse-changed" \
    "$project_dir/scripts/parse-images.sh" >/dev/null
)
assert_contains "$temp_dir/parse-changed" 'count=1'
assert_contains "$temp_dir/parse-changed" '"source_image":"redis:7","target_image":"","repo_tag":"redis:7"'

"$project_dir/scripts/validate-config.sh" >/dev/null
assert_contains "$GITHUB_OUTPUT" "source_registry=docker.io"

SOURCE_IMAGE="ghcr.io/example/app:v1" GITHUB_OUTPUT="$temp_dir/private-output" \
  "$project_dir/scripts/validate-config.sh" >/dev/null
assert_contains "$temp_dir/private-output" "source_registry=ghcr.io"

TARGET_IMAGE="" GITHUB_OUTPUT="$temp_dir/no-target-output" \
  "$project_dir/scripts/validate-config.sh" >/dev/null

if TARGET_IMAGE="MissingNamespace:latest" "$project_dir/scripts/validate-config.sh" >/dev/null 2>&1; then
  fail "无效的 target_image 未被拒绝"
fi

if TARGET_IMAGE="mirror/../nginx:latest" "$project_dir/scripts/validate-config.sh" >/dev/null 2>&1; then
  fail "含无效路径段的 target_image 未被拒绝"
fi

if SOURCE_IMAGE="https://docker.io/library/nginx:latest" "$project_dir/scripts/validate-config.sh" >/dev/null 2>&1; then
  fail "带 URL 协议的 source_image 未被拒绝"
fi

if PUSH_TARGETS="selfregistry" SELFREGISTRY_REGISTRY="" "$project_dir/scripts/validate-config.sh" >/dev/null 2>&1; then
  fail "缺少自建 Registry 地址配置未被拒绝"
fi

if PUSH_TARGETS="selfregistry,tcr" TCR_PASSWORD="" "$project_dir/scripts/validate-config.sh" >/dev/null 2>&1; then
  fail "缺少 TCR 凭证未被拒绝"
fi

PUSH_TARGETS="myregistry" MYREGISTRY_REGISTRY="registry.internal.example.com" \
  MYREGISTRY_NAMESPACE="mirror" MYREGISTRY_USERNAME="robot" MYREGISTRY_PASSWORD="token" \
  GITHUB_OUTPUT="$temp_dir/custom-registry-output" \
  "$project_dir/scripts/validate-config.sh" >/dev/null

TARGET_IMAGE="" SELFREGISTRY_NAMESPACE="" GITHUB_OUTPUT="$temp_dir/no-namespace-output" \
  "$project_dir/scripts/validate-config.sh" >/dev/null

if PUSH_TARGETS="My-Registry!" SELFREGISTRY_REGISTRY="registry.internal.example.com" \
  SELFREGISTRY_USERNAME="robot" SELFREGISTRY_PASSWORD="token" TARGET_IMAGE="" \
  "$project_dir/scripts/validate-config.sh" >/dev/null 2>&1; then
  fail "无效的 PUSH_TARGETS 名称未被拒绝"
fi

mkdir -p "$temp_dir/bin"
cat > "$temp_dir/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$DOCKER_CALLS"
if [[ "${1:-}" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
  cat <<'OUTPUT'
Name: demo.tencentcloudcr.com/mirror/nginx:1.27
Digest: sha256:0123456789abcdef
OUTPUT
elif [[ "${1:-}" == "save" ]]; then
  out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output|-o)
        out="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ -n "$out" ]] && : > "$out"
fi
MOCK
chmod +x "$temp_dir/bin/docker"

cat > "$temp_dir/bin/regctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$REGCTL_CALLS"
MOCK
chmod +x "$temp_dir/bin/regctl"

export PATH="$temp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DOCKER_CALLS="$temp_dir/docker-calls"
export REGCTL_CALLS="$temp_dir/regctl-calls"
export GITHUB_OUTPUT="$temp_dir/sync-output"
export GITHUB_STEP_SUMMARY="$temp_dir/summary"

TARGET_IMAGE="" "$project_dir/scripts/sync-image.sh" >/dev/null
assert_contains "$REGCTL_CALLS" "image copy nginx:1.27 registry.internal.example.com/library/nginx:1.27"
assert_contains "$REGCTL_CALLS" "image copy nginx:1.27 demo.tencentcloudcr.com/mirror/nginx:1.27"
assert_contains "$GITHUB_OUTPUT" "selfregistry_target_ref=registry.internal.example.com/library/nginx:1.27"
assert_contains "$GITHUB_OUTPUT" "tcr_target_ref=demo.tencentcloudcr.com/mirror/nginx:1.27"
assert_contains "$GITHUB_OUTPUT" "digest=sha256:0123456789abcdef"
assert_contains "$GITHUB_STEP_SUMMARY" "镜像同步成功"
assert_contains "$GITHUB_STEP_SUMMARY" "registry.internal.example.com/library/nginx:1.27"

: > "$REGCTL_CALLS"
TARGET_IMAGE="mirror/nginx:1.27" "$project_dir/scripts/sync-image.sh" >/dev/null
assert_contains "$REGCTL_CALLS" "image copy nginx:1.27 registry.internal.example.com/mirror/nginx:1.27"
assert_contains "$REGCTL_CALLS" "image copy nginx:1.27 demo.tencentcloudcr.com/mirror/nginx:1.27"

: > "$REGCTL_CALLS"
: > "$DOCKER_CALLS"
TARGET_IMAGE="" COPY_MODE="single-platform" "$project_dir/scripts/sync-image.sh" >/dev/null
assert_contains "$DOCKER_CALLS" "pull --platform linux/amd64 nginx:1.27"
assert_contains "$DOCKER_CALLS" "save --output "
assert_contains "$REGCTL_CALLS" "registry set --skip-check --blob-max -1 --blob-chunk 52428800 --req-concurrent 3 registry.internal.example.com"
assert_contains "$REGCTL_CALLS" "image import registry.internal.example.com/library/nginx:1.27"
assert_contains "$REGCTL_CALLS" "image import demo.tencentcloudcr.com/mirror/nginx:1.27"
if grep -Fq -- "image copy" "$REGCTL_CALLS"; then
  fail "单平台模式不应再使用 regctl image copy"
fi

: > "$REGCTL_CALLS"
: > "$DOCKER_CALLS"
env -u PUSH_TARGETS TARGET_IMAGE="" COPY_MODE="single-platform" "$project_dir/scripts/sync-image.sh" >/dev/null
assert_contains "$DOCKER_CALLS" "pull --platform linux/amd64 nginx:1.27"
assert_contains "$REGCTL_CALLS" "image import registry.internal.example.com/library/nginx:1.27"
if grep -Fq -- "demo.tencentcloudcr.com" "$REGCTL_CALLS"; then
  fail "未设置 PUSH_TARGETS 时默认不应推送到 TCR"
fi

: > "$REGCTL_CALLS"
TARGET_IMAGE="" SELFREGISTRY_NAMESPACE="" COPY_MODE="single-platform" "$project_dir/scripts/sync-image.sh" >/dev/null
assert_contains "$REGCTL_CALLS" "image import registry.internal.example.com/nginx:1.27"

export CRANE_CALLS="$temp_dir/crane-calls"
cat > "$temp_dir/bin/crane" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CRANE_CALLS"
MOCK
chmod +x "$temp_dir/bin/crane"

: > "$REGCTL_CALLS"
: > "$DOCKER_CALLS"
: > "$CRANE_CALLS"
TARGET_IMAGE="" COPY_MODE="single-platform" "$project_dir/scripts/sync-image.sh" >/dev/null
assert_contains "$DOCKER_CALLS" "pull --platform linux/amd64 nginx:1.27"
assert_contains "$CRANE_CALLS" "push "
assert_contains "$CRANE_CALLS" " registry.internal.example.com/library/nginx:1.27"
assert_contains "$CRANE_CALLS" " demo.tencentcloudcr.com/mirror/nginx:1.27"
if grep -Fq -- "image import" "$REGCTL_CALLS"; then
  fail "已安装 crane 时不应再使用 regctl image import"
fi

echo "All tests passed"
