# Container Image Sync (self-hosted registry + Tencent TCR)

通过 GitHub Actions 将 Docker Hub、GHCR 或其他 OCI Registry 中的镜像同步到目标 Registry。默认推送到自建 Registry（`distribution/distribution` 部署的 Registry v2，配置名 `selfregistry`），也可以同时推送到腾讯云 TCR。无需自建 CI 服务器，支持完整保留多架构镜像，也支持只同步指定平台。

默认只把每个镜像推送到自建 Registry（`PUSH_TARGETS=selfregistry`），需要时可同时写入 TCR 等其它 Registry。

## 功能

- 在 `images.txt` 中每行写一个镜像，提交后自动同步本次新增或修改的行
- 默认推送到自建 Registry，可用 `PUSH_TARGETS=selfregistry,tcr` 一次写入多个 Registry
- Registry 地址、命名空间、账号密码全部通过 GitHub Variables / Secrets 配置，不需要改代码
- 也可以在 GitHub Actions 页面手动输入源镜像与目标镜像
- 默认只同步 `linux/amd64`，避免海外 GitHub 运行器向国内 Registry 推送多架构镜像时长时间无输出
- 可切换为完整多平台复制，或指定其他单平台
- 支持需要账号密码的私有源仓库
- 输入校验、最小 GitHub Token 权限、并发保护及执行摘要

## 一、准备目标 Registry

### 1. 自建 Registry（默认目标）

1. 用 `distribution/distribution`（Registry v2）部署，并开启 HTTP Basic 认证与 HTTPS。
2. 准备一个可推送的账号密码（例如 htpasswd 生成），按需创建对应的存储路径。
3. 记下 Registry 域名，例如 `registry.internal.example.com`（不要带 `https://`，也不要写仓库路径）。

> `distribution/distribution` 默认不提供 TLS 证书。GitHub 托管运行器上的 Docker 与 `regctl` 都会校验证书，因此自建 Registry 必须配置受信任的 HTTPS 证书（例如 Let's Encrypt 或内网 CA 签发的证书），否则需要在运行器上额外配置 CA 或 `insecure-registries`。不要把证书校验关掉。

### 2. 腾讯云 TCR（可选）

只有当 `PUSH_TARGETS` 里包含 `tcr` 时才需要准备：

1. 在腾讯云容器镜像服务中创建实例、命名空间和镜像仓库。
2. 在 TCR 的“访问凭证”页面创建有目标仓库推送权限的长期凭证。自动化场景建议使用独立的服务级账号并遵循最小权限原则。
3. 记下实例登录域名，例如：
   - 企业版：`demo.tencentcloudcr.com`
   - 个人版：`ccr.ccs.tencentyun.com`

> 如果 Registry 开启了访问白名单，需要允许 GitHub 托管运行器访问。GitHub 托管运行器的出口地址范围会变化；生产环境更适合使用固定出口 IP 的自托管运行器，或根据组织安全策略配置访问方式。

## 二、配置 GitHub 仓库

将本项目推送到 GitHub 后，打开：

`Settings` → `Secrets and variables` → `Actions`

在 **Variables** 中创建：

| 名称 | 示例 | 说明 |
| --- | --- | --- |
| `PUSH_TARGETS` | `selfregistry,tcr` | 要推送的 Registry 名称列表，顺序即优先级，默认为 `selfregistry` |
| `SELFREGISTRY_REGISTRY` | `registry.internal.example.com` | 自建 Registry 域名，只填域名，不含协议和仓库路径 |
| `SELFREGISTRY_NAMESPACE` | `mirror` | 可选。未写目标镜像时自建 Registry 使用的路径前缀；留空则直接推到顶层仓库 |
| `TCR_REGISTRY` | `demo.tencentcloudcr.com` | TCR 域名，仅在 `PUSH_TARGETS` 含 `tcr` 时需要 |
| `TCR_NAMESPACE` | `mirror` | 未写目标镜像时 TCR 使用的命名空间，仅在含 `tcr` 时需要 |
| `COPY_MODE` | `single-platform` | 由 `images.txt` 触发时的同步模式，默认 `single-platform` |
| `PLATFORM` | `linux/amd64` | 单平台模式使用的架构 |

在 **Secrets** 中创建凭证（推荐，会被 `***` 掩码）：

| 名称 | 说明 |
| --- | --- |
| `SELFREGISTRY_USERNAME` / `SELFREGISTRY_PASSWORD` | 自建 Registry 的账号密码 |
| `TCR_USERNAME` / `TCR_PASSWORD` | TCR 访问凭证，仅在 `PUSH_TARGETS` 含 `tcr` 时需要 |
| `SOURCE_USERNAME` / `SOURCE_PASSWORD` | 私有源 Registry 凭证，公共源不需要 |

凭证也可以放在 **Variables** 中（`SELFREGISTRY_USERNAME`、`TCR_PASSWORD` 等同名）。同名时 Secrets 优先，Variables 作为兜底，例如 `SELFREGISTRY_USERNAME` 未建 Secret 时会读取同名 Variable。注意 Variables 是明文，任何有仓库读取权限的人都能看到，只建议用于权限极小的临时账号。

### 命名规则

`PUSH_TARGETS` 里的每个名称 `NAME` 都会自动映射到同名大写前缀的配置：

| 变量/密钥 | 含义 |
| --- | --- |
| `NAME_REGISTRY` | Registry 域名（必填） |
| `NAME_NAMESPACE` | 可选。未写显式目标镜像时使用的路径前缀；留空则不加前缀 |
| `NAME_USERNAME` / `NAME_PASSWORD` | 该 Registry 的凭证（必填） |

所以自建 Registry 直接叫 `selfregistry` 即可；也可以换成任意名字，例如 `PUSH_TARGETS=selfregistry,tcr` 时分别读取 `SELFREGISTRY_*` 与 `TCR_*`。名称只允许字母、数字、`_`、`-`。

`PUSH_TARGETS` 中列出的每个 Registry 都必须同时配置对应的 `*_REGISTRY`、`*_USERNAME`、`*_PASSWORD`；`*_NAMESPACE` 可选。默认只推送到自建 Registry，因此 TCR 的配置可以暂时不填。

公共源镜像不要配置 `SOURCE_USERNAME` 和 `SOURCE_PASSWORD`。私有源仓库必须同时配置二者；工作流会根据源镜像地址自动识别 Registry 域名。

## 三、运行同步

### 方式一：编辑 `images.txt`（推荐）

在仓库根目录的 `images.txt` 中每行写一个镜像，提交并推送后会自动触发同步。空行和 `#` 开头的注释会被忽略。

```text
# 只写源镜像：每个 Registry 使用自己的命名空间
nginx:1.27
ghcr.io/example/app:v1

# 也可以显式指定目标路径（不含 Registry 域名），该路径会用于所有 Registry
nginx:1.27  mirror/nginx:1.27
```

假设默认 `PUSH_TARGETS=selfregistry`、`SELFREGISTRY_NAMESPACE=mirror`，上面三行同步后的目标分别是：

```text
registry.internal.example.com/mirror/nginx:1.27
registry.internal.example.com/mirror/app:v1
registry.internal.example.com/mirror/nginx:1.27
```

如果还设置了 `PUSH_TARGETS=selfregistry,tcr` 和 `TCR_NAMESPACE=mirror`，则每个镜像会再多推一份到 `demo.tencentcloudcr.com/mirror/...`。

同一提交可以写多行，会并行同步；只同步本次新增或修改的行，不会重跑文件里已有的旧条目。只写源镜像时，目标仓库名取最后一段路径，因此 `bitnami/redis:7.2` 和 `redis:7.2` 都会落到 `<命名空间>/redis:7.2`；有冲突时请显式写出目标镜像。手动运行工作流时仍可按下面的方式同步单个镜像。

### 方式二：手动运行工作流

1. 打开 GitHub 仓库的 `Actions` 页面。
2. 选择 `Sync container images`。
3. 点击 `Run workflow`，填写参数：

| 参数 | 示例 | 说明 |
| --- | --- | --- |
| `source_image` | `nginx:1.27` | 源镜像完整引用，也可使用 digest（使用 digest 时必须填目标路径） |
| `target_image` | `mirror/nginx:1.27` | 所有 Registry 内共用的路径，不含 Registry 域名；留空则使用各自命名空间 |
| `copy_mode` | `single-platform` | `single-platform` 或 `all-platforms` |
| `platform` | `linux/amd64` | 仅单平台模式使用 |

完整目标地址会被组合为：

```text
${SELFREGISTRY_REGISTRY}/${target_image}   例如 registry.internal.example.com/mirror/nginx:1.27
```

`PUSH_TARGETS` 里的其它 Registry 同理，例如含 `tcr` 时还会推送到 `${TCR_REGISTRY}/${target_image}`。

### 两种同步模式

- `single-platform`（默认）：执行 `docker pull --platform`、`docker tag` 和 `docker push`，只同步一个平台，并推送到所有目标 Registry。GitHub 托管运行器在海外，推送到国内 Registry 时请用这个模式。
- `all-platforms`：使用固定版本的 `regctl` 复制完整多架构清单。`nginx` 官方镜像还包含 Windows 等平台，从海外传到国内经常要十几分钟甚至更久，期间默认几乎没有进度日志，看起来像卡住。确实需要多架构时再选用。

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
- 为 CI/CD 创建独立的 TCR 服务级账号与自建 Registry 账号，仅授予目标命名空间或仓库的推送权限。
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
├── scripts/sync-image.sh             # 镜像同步实现（多 Registry 推送）
└── tests/test-scripts.sh             # 无外部依赖的脚本测试
```

## 参考文档

- [GitHub：手动运行工作流](https://docs.github.com/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
- [distribution/distribution（Registry v2）](https://github.com/distribution/distribution)
- [腾讯云 TCR：用户级账号管理](https://cloud.tencent.com/document/product/1141/41829)
- [Docker：使用 password-stdin 登录 Registry](https://docs.docker.com/reference/cli/docker/login/)
- [regctl：跨 Registry 复制镜像](https://regclient.org/cli/regctl/image/copy/)
