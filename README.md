# TCR Image Sync

通过 GitHub Actions 将 Docker Hub、GHCR 或其他 OCI Registry 中的镜像同步到腾讯云容器镜像服务 TCR。无需自建服务器，支持完整保留多架构镜像，也支持只同步指定平台。

## 功能

- 在 `images.txt` 中每行写一个镜像，提交后自动同步本次新增或修改的行
- 也可以在 GitHub Actions 页面手动输入源镜像与目标镜像
- 默认同步全部平台（例如 `linux/amd64`、`linux/arm64`）
- 可切换为单平台拉取、重打标签并推送
- 支持需要账号密码的私有源仓库
- 输入校验、最小 GitHub Token 权限、并发保护及执行摘要
- 密码仅通过 GitHub Actions Secrets 使用

## 一、准备腾讯云 TCR

1. 在腾讯云容器镜像服务中创建实例、命名空间和镜像仓库。
2. 在 TCR 的“访问凭证”页面创建有目标仓库推送权限的长期凭证。自动化场景建议使用独立的服务级账号并遵循最小权限原则。
3. 记下实例登录域名，例如：
   - 企业版：`demo.tencentcloudcr.com`
   - 个人版：`ccr.ccs.tencentyun.com`

> 如果 TCR 开启了公网访问白名单，需要允许 GitHub 托管运行器访问。GitHub 托管运行器的出口地址范围会变化；生产环境更适合使用固定出口 IP 的自托管运行器，或根据组织安全策略配置访问方式。

## 二、配置 GitHub 仓库

将本项目推送到 GitHub 后，打开：

`Settings` → `Secrets and variables` → `Actions`

在 **Variables** 中创建：

| 名称 | 示例 | 说明 |
| --- | --- | --- |
| `TCR_REGISTRY` | `demo.tencentcloudcr.com` | 只填域名，不含协议和仓库路径 |
| `TCR_NAMESPACE` | `mirror` | 未写目标镜像时使用的 TCR 命名空间，默认 `mirror` |

在 **Secrets** 中创建：

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `TCR_USERNAME` | 是 | TCR 访问凭证用户名 |
| `TCR_PASSWORD` | 是 | TCR 访问凭证密码 |
| `SOURCE_USERNAME` | 否 | 私有源 Registry 用户名 |
| `SOURCE_PASSWORD` | 否 | 私有源 Registry 密码或 Token |

公共源镜像不要配置 `SOURCE_USERNAME` 和 `SOURCE_PASSWORD`。私有源仓库必须同时配置二者；工作流会根据源镜像地址自动识别 Registry 域名。

## 三、运行同步

### 方式一：编辑 `images.txt`（推荐）

在仓库根目录的 `images.txt` 中每行写一个镜像，提交并推送后会自动触发同步。空行和 `#` 开头的注释会被忽略。

```text
# 只写源镜像：目标为 ${TCR_NAMESPACE}/<仓库名>:<标签>
nginx:1.27
ghcr.io/example/app:v1

# 也可以同时指定 TCR 目标（不含 TCR 域名）
nginx:1.27  mirror/nginx:1.27
```

上面三行同步后的目标分别是：

```text
${TCR_REGISTRY}/mirror/nginx:1.27
${TCR_REGISTRY}/mirror/app:v1
${TCR_REGISTRY}/mirror/nginx:1.27
```

同一提交可以写多行，会并行同步；只同步本次新增或修改的行，不会重跑文件里已有的旧条目。只写源镜像时，目标仓库名取最后一段路径，因此 `bitnami/redis:7.2` 和 `redis:7.2` 都会落到 `mirror/redis:7.2`；有冲突时请显式写出目标镜像。手动运行工作流时仍可按下面的方式同步单个镜像。

### 方式二：手动运行工作流

1. 打开 GitHub 仓库的 `Actions` 页面。
2. 选择 `Sync container image to Tencent TCR`。
3. 点击 `Run workflow`，填写参数：

| 参数 | 示例 | 说明 |
| --- | --- | --- |
| `source_image` | `nginx:1.27` | 源镜像完整引用，也可使用 digest |
| `target_image` | `mirror/nginx:1.27` | TCR 命名空间/仓库:标签，不含 TCR 域名 |
| `copy_mode` | `all-platforms` | `all-platforms` 或 `single-platform` |
| `platform` | `linux/amd64` | 仅单平台模式使用 |

完整目标地址会被组合为：

```text
${TCR_REGISTRY}/${target_image}
```

例如：

```text
demo.tencentcloudcr.com/mirror/nginx:1.27
```

### 两种同步模式

- `all-platforms`：使用固定版本的 `regctl` 在 Registry 之间复制镜像清单和各平台内容，适合保留官方镜像的多架构支持。
- `single-platform`：执行 `docker pull --platform`、`docker tag` 和 `docker push`，目标镜像只包含所选平台。

## 私有源仓库示例

如果源镜像是 `ghcr.io/acme/api:v2`：

1. 将 `SOURCE_USERNAME` 设置为 GHCR 用户名。
2. 将 `SOURCE_PASSWORD` 设置为具有读取该镜像权限的 Token。
3. 运行工作流时将 `source_image` 设置为 `ghcr.io/acme/api:v2`。

当前配置对整个仓库共用一组源仓库凭证。如果需要同时同步多个不同的私有 Registry，建议为它们分别使用 GitHub Environment 和对应 Secrets。

## 本地检查

无需真实 Registry 凭证即可运行脚本测试：

```bash
./tests/test-scripts.sh
```

实际同步需要本机已安装 Docker，并设置与工作流相同的环境变量，然后依次执行配置检查、Registry 登录与同步脚本。

## 安全建议

- 不要把账号、密码、Token 或完整 `docker login` 命令提交到仓库。
- 为 CI/CD 创建独立 TCR 服务级账号，仅授予目标命名空间或仓库的推送权限。
- 定期轮换长期凭证；发现泄露后立即禁用并重新生成。
- 对重要仓库可创建 GitHub Environment，增加审批和分支限制。
- 如需严格控制镜像来源，可在 `validate-config.sh` 中增加允许的 Registry 或命名空间白名单。

## 目录结构

```text
.
├── images.txt                        # 要同步的镜像清单，每行一个
├── .github/workflows/sync-image.yml  # GitHub Actions 工作流
├── scripts/parse-images.sh           # 解析镜像清单并生成任务矩阵
├── scripts/validate-config.sh        # 配置和输入校验
├── scripts/sync-image.sh             # 镜像同步实现
└── tests/test-scripts.sh             # 无外部依赖的脚本测试
```

## 参考文档

- [GitHub：手动运行工作流](https://docs.github.com/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
- [腾讯云 TCR：用户级账号管理](https://cloud.tencent.com/document/product/1141/41829)
- [Docker：使用 password-stdin 登录 Registry](https://docs.docker.com/reference/cli/docker/login/)
- [regctl：跨 Registry 复制镜像](https://regclient.org/cli/regctl/image/copy/)
