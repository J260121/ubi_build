# ImmortalWrt 云编译项目

基于 GitHub Actions 的 ImmortalWrt 云编译仓库，主要面向 MediaTek
Filogic（MT7981 /
MT7986）设备。工作流支持选择设备、指定源码版本、应用设备定制、选择 LuCI
主题、运行可选插件脚本、使用缓存编译，并上传固件 Artifact 或发布 GitHub
Release。

-   **仓库地址：** <https://github.com/J260121/ubi_build>
-   **主工作流：** `.github/workflows/0-optimized-v2.yml`
-   **默认源码：**
    `https://github.com/padavanonly/immortalwrt-mt798x-6.6.git`
-   **默认分支：** `openwrt-24.10-6.6`

> 本文按仓库 `main`
> 分支当前可访问的主工作流整理。源码分支、脚本及设备配置变动后，请以实际文件和
> Actions 运行日志为准。

## 目录结构

``` text
ubi_build/
├── .github/
│   └── workflows/
│       ├── 0.yml
│       └── 0-optimized-v2.yml       # 主云编译工作流
├── config/                            # 各设备的 OpenWrt 配置模板
│   ├── mt7981-QLB-4Pro.config
│   ├── mt7981-cudy-tr3000-128m.config
│   ├── mt7981-cudy-tr3000-256m.config
│   ├── mt7981-cudy-tr3000-512m.config
│   └── mt7986-ikuai-q6000-nand.config
├── devices/                           # 设备专用 DIY 脚本
│   ├── diy-cudy-tr3000-512MB.sh
│   ├── diy-qlb-4pro.sh
│   └── diy-ikuai-q6000-nand.sh
├── dts/                               # 设备树定制文件
├── scripts/                           # 可选插件脚本及公共脚本
├── theme/                             # LuCI 主题集成脚本
│   ├── diy-liquid.sh
│   └── diy-aurora.sh
├── package/
│   └── luci-compat-keep/              # LuCI 兼容相关内容
└── README.md
```

以上是核心目录示意，不代表每个目录只包含列出的文件。请通过
`tree -a -I '.git'` 获取当前分支的完整文件清单。

## 功能概览

-   **多设备编译：** 支持选择单台设备或选择 `all` 创建 Matrix 构建任务。
-   **自定义源码：** 可指定源码仓库、分支和 Commit。
-   **设备适配：** 使用设备配置、设备专用脚本及 DTS 文件进行定制。
-   **主题选择：** 工作流提供 `liquid` 与 `aurora` 两个选项。
-   **可选插件脚本：** 通过 `plugin_scripts` 输入执行 `scripts/`
    目录中的一个或多个脚本。
-   **构建缓存：** 使用 ccache 和 OpenWrt `dl` 下载目录缓存。
-   **固件归档：** 上传 GitHub Actions Artifact，并收集构建信息。
-   **Release 发布：** 可选择创建正式 Release 或预发布版本。

## 工作流执行流程

``` mermaid
flowchart TD
    A[workflow_dispatch 或 repository_dispatch] --> B[解析设备和编译参数]
    B --> C[生成 Matrix]
    C --> D[初始化 Ubuntu Runner]
    D --> E[克隆 ImmortalWrt 源码]
    E --> F[准备 DTS 和定制文件]
    F --> G[更新并安装 Feeds]
    G --> H[执行设备专用 DIY]
    H --> I[加载设备 .config]
    I --> J[执行主题集成脚本]
    J --> K[执行用户选择的插件脚本]
    K --> L[make defconfig]
    L --> M[恢复/保存缓存]
    M --> N[make download]
    N --> O[并行编译]
    O --> P[整理固件与构建信息]
    P --> Q[上传 Artifact]
    Q --> R[按条件发布 Release]
```

### 主要阶段

1.  **参数解析：**
    读取设备、源码仓库、分支、Commit、主题、插件脚本和发布选项。
2.  **Matrix 生成：** 每台设备由独立的构建 Job 处理。
3.  **源码获取：** 将源码克隆到 `/workdir/openwrt`。
4.  **定制文件准备：** 将仓库中的 DTS
    文件复制到源码对应目录，并准备设备脚本。
5.  **Feeds：** 执行 `./scripts/feeds update -a` 与
    `./scripts/feeds install -a`。
6.  **设备定制与配置：** 执行对应设备脚本，再将设备配置复制为源码目录的
    `.config`。
7.  **主题与插件：** 运行所选主题脚本和 `plugin_scripts` 中指定的脚本。
8.  **配置生成：** 执行 `make defconfig`，由构建系统处理依赖和配置。
9.  **缓存与编译：** 配置 ccache，下载源码依赖，再使用 `nproc`
    确定并行编译数。
10. **归档发布：** 整理固件和构建信息，上传 Artifact；满足条件时创建
    Release。

## 支持的设备

主工作流目前列出的设备参数如下：

  设备参数             配置文件
  -------------------- -----------------------------------------
  `cudy-tr3000-512M`   `config/mt7981-cudy-tr3000-512m.config`
  `cudy-tr3000-256M`   `config/mt7981-cudy-tr3000-256m.config`
  `cudy-tr3000-128M`   `config/mt7981-cudy-tr3000-128m.config`
  `QLB-4Pro`           `config/mt7981-QLB-4Pro.config`
  `ikuai-q6000-nand`   `config/mt7986-ikuai-q6000-nand.config`
  `all`                为以上设备生成 Matrix

**注意：** 当前工作流中，Cudy TR3000 256M 和 128M 的设备 DIY
分支是空操作（对应脚本调用被注释）。这不一定阻止构建，但如果设备需要独立的镜像参数或硬件修改，应先补全并验证对应定制逻辑。

## 启动云编译

1.  打开仓库的 **Actions** 页面。

2.  选择 `ImmortalWrt Builder DIY fixed` 对应的工作流（文件为
    `0-optimized-v2.yml`）。

3.  点击 **Run workflow**。

4.  选择设备：

    -   `cudy-tr3000-512M`
    -   `cudy-tr3000-256M`
    -   `cudy-tr3000-128M`
    -   `QLB-4Pro`
    -   `ikuai-q6000-nand`
    -   `all`

5.  按需设置源码仓库、分支和 Commit。Commit 留空时使用指定分支当前代码。

6.  选择主题 `liquid` 或 `aurora`。

7.  如需执行额外插件脚本，在 `plugin_scripts`
    中填写脚本文件名，多个文件用英文逗号分隔，例如：

    ``` text
    diy-PassWall.sh,diy-iStore.sh
    ```

    文件必须存在于仓库的 `scripts/` 目录，且文件名必须以 `.sh`
    结尾。脚本所使用的仓库和分支也必须可访问。

8.  设置是否发布 Release，以及是否创建预发布版本。

9.  点击运行，在 Actions 日志中查看每台设备的构建过程。

工作流也支持 `repository_dispatch`，其 `client_payload`
应提供工作流所读取的参数字段，例如
`device`、`repo`、`branch`、`commit`、`plugin_theme`、`plugin_scripts`、`release`
和 `prerelease`。

## 主题集成

工作流的 `plugin_theme` 选项当前包括：

-   `liquid`：执行 `theme/diy-liquid.sh`
-   `aurora`：执行 `theme/diy-aurora.sh`

添加新主题时，需要同步修改：

1.  将主题脚本放到 `theme/` 目录。
2.  在 `workflow_dispatch.inputs.plugin_theme.options` 中增加选项。
3.  在 `Load Theme` 步骤中增加对应的 `case` 分支。
4.  确认主题源码仓库 URL、分支和包目录正确。
5.  在 `make defconfig` 后验证主题配置仍然启用。

不要将主题克隆到根目录
`/luci-theme-liquid`。应使用源码工作目录下的路径，例如
`/workdir/openwrt/package/...`，并根据主题上游的真实目录结构决定最终位置。

例如，主题包确实位于 `package/luci-theme-liquid/` 且包名确实为
`luci-theme-liquid` 时，可以检查：

``` bash
# 进入 OpenWrt 源码目录
cd /workdir/openwrt

# 确认主题 Makefile 存在
test -f package/luci-theme-liquid/Makefile || {
    echo "ERROR: luci-theme-liquid Makefile 不存在"
    exit 1
}

# 确保主题配置已写入 .config
grep -qxF 'CONFIG_PACKAGE_luci-theme-liquid=y' .config \
    || echo 'CONFIG_PACKAGE_luci-theme-liquid=y' >> .config

# 生成最终配置
make defconfig

# 确认 defconfig 后主题仍被启用
grep -qxF 'CONFIG_PACKAGE_luci-theme-liquid=y' .config || {
    echo "ERROR: luci-theme-liquid 配置未生效"
    exit 1
}
```

这段检查适用于上述目录与包名假设。若主题通过 Feeds 提供，或其 Makefile
位于其他目录，应按实际包定义调整。仅向 `.config`
添加一行不能保证主题包已被构建系统识别。

## 添加插件脚本

将插件脚本放在 `scripts/`，然后在 Actions 输入框 `plugin_scripts`
中填写文件名。多个脚本用英文逗号分隔。

示例：

``` text
diy-PassWall.sh,diy-iStore.sh
```

建议脚本：

-   使用 Bash 兼容语法，并在关键步骤失败时返回非零状态。
-   在克隆前检查仓库 URL、分支和可访问性。
-   使用源码工作目录下的相对路径或明确路径，避免尝试在根目录创建文件夹。
-   确认新增软件源已经执行 Feeds 更新与安装。
-   不要重复执行主工作流已经完成的操作。
-   修改 `.config` 后，通过 `make defconfig` 和 `grep`
    验证关键包是否仍然启用。
-   不要在仓库、日志或 README 中写入访问 Token、密码等敏感凭据。

检查所有已启用的 LuCI 主题：

``` bash
grep '^CONFIG_PACKAGE_luci-theme-.*=y$' .config || true
```

单独检查 Liquid 主题：

``` bash
grep -qxF 'CONFIG_PACKAGE_luci-theme-liquid=y' .config || {
    echo "ERROR: luci-theme-liquid 未启用"
    exit 1
}
```

## 缓存与超时

主工作流当前可见的主要设置：

  项目                当前设置
  ------------------- -----------------------
  Runner              `ubuntu-22.04`
  Build Job 超时      `200` 分钟
  ccache 目录         `/workdir/.ccache`
  ccache 最大容量     `6G`
  下载缓存目录        `/workdir/openwrt/dl`
  Artifact 保留时间   7 天

### 编译超时优化建议

-   每次先构建单台设备，确认构建稳定后再选择 `all`。
-   查看日志分别统计 Feeds、下载和编译阶段耗时。
-   检查 ccache 是否命中、下载缓存是否恢复。
-   尽量固定源码分支或 Commit，减少非必要的缓存失效。
-   减少不需要的软件包和重复执行的脚本。
-   结合账户计划、Runner 类型和并发限制决定是否提高超时。

`timeout-minutes` 只控制 Job 的最长运行时间，不能突破 GitHub 对 Runner
或账户的限制。Matrix 的设备 Job
相互独立；并行可以缩短总等待时间，但会占用更多并发资源。

## 构建产物

### Actions Artifact

打开 **Actions**，进入具体运行记录，在 Artifacts
区域下载构建产物。主工作流会整理固件文件，并生成包含构建信息的归档；具体文件名以运行结果为准。

### GitHub Release

只有在发布开关开启、构建依赖成功且发布 Job 条件满足时，固件才会进入
Release。Artifact 上传成功并不意味着 Release 一定成功。

如发布失败，请检查：

-   Release 开关和预发布开关。
-   Release Job 的 `needs` 和 `if` 条件。
-   `contents: write` 权限与 Token。
-   固件文件是否已收集。
-   是否存在重复资产名。
-   发布步骤的完整错误日志。

## 常见问题

### `Permission denied`：无法创建 `/luci-theme-liquid`

**原因：** `git clone` 的目标路径使用了根目录绝对路径，而当前用户无权在
`/` 下创建目录。

错误写法：

``` bash
git clone https://github.com/OWNER/REPO.git /luci-theme-liquid
```

应改为源码目录下的路径，并替换为真实主题仓库 URL：

``` bash
cd /workdir/openwrt
git clone --depth 1 https://github.com/OWNER/REPO.git package/luci-theme-liquid
```

请先确认主题仓库确实可以公开访问，并且包目录结构符合 OpenWrt 的要求。

### `fatal: could not read Username for 'https://github.com'`

常见原因包括 URL 不正确、仓库为私有、分支不存在或仓库要求认证。先检查
URL 和分支，再使用 `git ls-remote` 验证。私有仓库应通过 GitHub Actions
Secrets 提供凭据，不能将 Token 直接写进脚本。

### `make defconfig` 后主题配置消失

检查主题包是否被构建系统发现、包名与配置符号是否一致、依赖是否满足，以及
Feeds 是否已初始化。应同时查看 `make defconfig` 的输出和最终
`.config`，不能只看脚本是否成功执行。

### Matrix 构建超时

先从日志确认耗时发生在依赖下载、Feeds
还是正式编译阶段，再决定优化缓存、减少包数量、调整并发或超时。不要只靠延长超时掩盖下载失败或编译错误。

### 固件没有上传

检查编译是否成功、`bin/targets`
中是否生成固件，以及整理固件步骤是否找到对应文件。根据 Artifact
上传步骤的日志定位路径或文件匹配问题。

### Release 报 `HttpError: Not Found`

核对 Release 是否已创建、Release ID 和资产是否对应、Token
是否有权限，以及资产是否被其他步骤删除或重命名。需要结合该次运行日志判断，不能仅凭错误文本确定单一原因。

## 本地查看完整目录

``` bash
# 克隆仓库
git clone --depth 1 https://github.com/J260121/ubi_build.git
cd ubi_build

# 查看完整目录树（需要安装 tree）
tree -a -I '.git'

# 只查看关键目录
tree -a .github config devices scripts dts theme package

# 保存目录树
tree -a -I '.git' > structure.txt
```

## 维护建议

-   修改工作流后先运行单设备构建，再进行多设备 Matrix 测试。
-   保持设备配置、设备 DIY、主题集成和插件逻辑职责分离。
-   新增包时先验证上游仓库、分支、Makefile 和配置符号。
-   保存源码 Commit、最终 `.config` 和失败日志，便于复现。
-   不要把访问令牌、密码或其他凭据提交到仓库。

## 免责声明

本仓库用于个人学习、测试和固件构建。刷写前请确认设备型号、硬件版本和镜像类型匹配，并提前备份配置。错误的固件或刷写操作可能导致设备无法启动。第三方源码、软件包和主题的维护状态由其上游项目决定。
