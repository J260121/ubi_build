# QQ群 与 闲鱼
<img src="image/qq-group.png">

# ImmortalWrt 云编译项目

基于 GitHub Actions 的 ImmortalWrt 云编译仓库，主要面向 MediaTek Filogic（MT7981 / MT7986）设备。通过 GitHub Actions 可以选择设备、源码分支、LuCI 主题和可选插件脚本，并将构建产物保存为 Actions Artifact 或发布到 GitHub Releases。

<p align="center">
  <a href="https://github.com/J260121/ubi_build/actions">
    <img src="https://img.shields.io/badge/GitHub%20Actions-云编译-blue?logo=githubactions" alt="GitHub Actions 云编译">
  </a>
  <a href="https://github.com/J260121/ubi_build/releases">
    <img src="https://img.shields.io/badge/固件-Releases-brightgreen?logo=github" alt="固件 Releases">
  </a>
  <a href="https://github.com/J260121/ubi_build">
    <img src="https://img.shields.io/github/stars/J260121/ubi_build?style=social" alt="GitHub stars">
  </a>
</p>

## 项目地址

- 仓库：<https://github.com/J260121/ubi_build>
- 云编译：<https://github.com/J260121/ubi_build/actions>
- 固件发布：<https://github.com/J260121/ubi_build/releases>
- 主工作流：`.github/workflows/0-optimized-v2.yml`
- 默认源码仓库：<https://github.com/padavanonly/immortalwrt-mt798x-6.6>
- 默认源码分支：`openwrt-24.10-6.6`

## 项目功能

- **GitHub Actions 云编译**：无需在本地搭建完整编译环境。
- **多设备构建**：支持选择单台设备，也可选择 `all` 运行 Matrix 构建。
- **自定义源码**：可按工作流输入项指定源码仓库、分支或 Commit。
- **设备定制**：通过 `config/`、`devices/` 和 `dts/` 管理设备配置与定制内容。
- **LuCI 主题**：工作流支持 `liquid`、`aurora` 主题选项（以当前分支工作流实际配置为准）。
- **可选插件脚本**：可从 `scripts/` 选择脚本，在构建时集成额外功能。
- **构建缓存**：使用 ccache 和源码下载缓存，减少重复构建耗时。
- **固件归档**：可下载 Actions Artifact；启用发布选项后，也可将固件发布到 GitHub Releases。

## 当前列出的设备

| 工作流设备参数 | 配置文件 |
|---|---|
| `cudy-tr3000-512M` | `config/mt7981-cudy-tr3000-512m.config` |
| `cudy-tr3000-256M` | `config/mt7981-cudy-tr3000-256m.config` |
| `cudy-tr3000-128M` | `config/mt7981-cudy-tr3000-128m.config` |
| `QLB-4Pro` | `config/mt7981-QLB-4Pro.config` |
| `ikuai-q6000-nand` | `config/mt7986-ikuai-q6000-nand.config` |
| `all` | 为上述设备创建 Matrix 构建任务 |

> 设备列表和配置以当前分支的工作流及 `config/` 文件为准。刷写前务必核对具体硬件版本、存储类型和镜像类型。

## 如何启动云编译

1. 打开 [Actions 页面](https://github.com/J260121/ubi_build/actions)。
2. 选择工作流 `ImmortalWrt Builder DIY fixed`（对应 `.github/workflows/0-optimized-v2.yml`，名称以仓库当前显示为准）。
3. 点击 **Run workflow**。
4. 选择需要编译的设备；首次测试建议先选择单台设备。
5. 按需填写源码仓库、分支和 Commit。
6. 选择主题，例如 `liquid` 或 `aurora`。
7. 如需执行插件脚本，在 `plugin_scripts` 输入框填写 `scripts/` 目录下的脚本文件名；多个脚本用英文逗号分隔，例如：

   ```text
   diy-passwall.sh,diy-istore.sh
   ```

   请确认脚本文件确实存在，且名称与仓库中的文件一致。
8. 按需启用 Release 发布和预发布选项。
9. 点击 **Run workflow**，进入本次运行记录查看各阶段日志。

> 工作流输入项、脚本名称和可选值可能随仓库更新而变化，请以 Actions 页面当前实际显示为准。

## 如何下载编译产物

### 方法一：从 Actions 下载

1. 打开 [Actions](https://github.com/J260121/ubi_build/actions)。
2. 进入对应的成功运行记录。
3. 在页面底部的 **Artifacts** 区域下载归档。
4. 解压后，按设备型号和镜像类型选择固件。

Actions Artifact 可能设有保留期限，不建议将其作为唯一的长期备份。

### 方法二：从 GitHub Releases 下载

打开 [Releases 固件发布页](https://github.com/J260121/ubi_build/releases)，选择对应版本并下载所需资产。

若本次构建没有出现在 Releases 中，请检查工作流是否启用了 Release 发布、构建是否成功，以及发布任务的权限和日志。Actions Artifact 上传成功不代表 Release 一定发布成功。

## 目录结构

```text
ubi_build/
├── .github/
│   └── workflows/
│       ├── 0.yml
│       └── 0-optimized-v2.yml   # 主云编译工作流
├── config/                      # 设备 .config 模板
├── devices/                     # 设备专用 DIY 脚本
├── dts/                         # 设备树定制文件
├── scripts/                     # 可选插件与公共脚本
├── theme/                       # LuCI 主题集成脚本
└── package/
    └── luci-compat-keep/         # LuCI 兼容相关内容
```

以上为主要目录示意，实际内容请以仓库当前文件为准。

## 插件与主题脚本说明

- 插件脚本通常放在 `scripts/` 目录。
- 主题脚本放在 `theme/` 目录。
- 新增脚本后，应确认主工作流会调用该脚本，并检查脚本执行时机是否正确。
- 如果脚本新增软件源，应确保 Feeds 更新、安装及包配置顺序正确。
- 修改 `.config` 后，应通过 `make defconfig` 和构建日志确认配置真正生效。
- 请勿将 GitHub Token、密码或其他敏感信息写入脚本、日志或 README。

## 常见问题

### 编译超时

- 先检查耗时发生在 Feeds 更新、依赖下载还是正式编译阶段。
- 优先检查缓存是否命中，并尽量固定源码分支或 Commit。
- 先单设备验证，再进行多设备 Matrix 构建。
- `timeout-minutes` 不能突破 GitHub 对 Runner、账户计划或并发资源的限制。

### 固件没有出现在 Releases

- 确认工作流的 Release 开关已启用。
- 确认编译和发布 Job 均成功。
- 检查发布 Job 的 `needs`、`if` 条件及 `contents: write` 权限。
- 检查资产收集路径、文件名冲突和上传步骤日志。

### 刷机后无法启动

- 确认固件与设备型号、硬件版本和 NAND/eMMC 存储类型完全匹配。
- 刷写前备份配置，并确认拥有可用的恢复方式。
- 不要将其他型号的固件仅因芯片相同就直接刷入。

## 免责声明

本项目用于个人学习、测试及固件构建。固件和第三方组件可能存在风险，使用者应自行确认来源、设备兼容性和刷写方式。错误刷写可能导致设备无法启动或数据丢失。请在操作前备份重要数据；使用本项目产生的后果由使用者自行承担。

## 致谢

感谢 ImmortalWrt、OpenWrt 及相关设备适配、软件包、主题和插件项目的维护者。
