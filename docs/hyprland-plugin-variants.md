# Hyprland 插件双线维护

Viewflow 维护 release 和 main 两条源码兼容线。两个插件共用源码，不复制插件目录。
本页记录构建约定、选择规则、维护步骤和 2026-11-01 的验证范围。

## 维护目标

| 线 | 版本 | 固定的上游提交 |
|---|---|---|
| release | v0.57.0 | `0aa6745f705f2c4b0a5004eb019ef76e5bbdb426` |
| main | 0.57.0 开发线 | `d55a55d72a2ecfbb31b875b0b45c27559ce86691` |
| 本机 fork 回归 | 0.56.0，main-based | `e5a03b6a5ce64ec4c85954649bad4df083627574` |

这些提交来自任务指定的快照，不表示未来的最新提交。不要用本地短标签代替上游提交。
本机 Hyprland 仓库的 `v0.57.0` 标签指向 fork 的 `f6725e43e`，并非表中的上游 release。
脚本默认使用完整提交，避免标签重名。

上游 0.57 的 `renderLayer` 比旧 fork 多一个 `workspaceScene` 参数。
`platform/hyprland-compat/render_layer.hpp` 用编译期函数签名选择六参数或七参数调用。
新增参数使用上游默认值 `false`。其余源码直接使用当前头文件。
release、main 和 fork 均有 `desktop/view/window/Window.hpp`，本次不需要改变该路径。
兼容修改不涉及 `PLUGIN_EXIT`、卸载生命周期、代理窗口状态或拖动策略。

## ABI 与包结构

插件 ABI 取决于完整 Hyprland 提交和构建依赖的 ABI。
版本号、tag 和“同属 main”均不足以证明二进制兼容。
Hyprland 的 `abiHash` 来自 `__hyprland_api_get_hash()`。
插件仍保留原有 hash 检查和 `PLUGIN_API_VERSION` 检查。

Linux 包的相关内容：

```text
plugins/release/<api_hash>/viewflow-hyprland.so
plugins/release/<api_hash>/viewflow-capture.so
plugin-source/platform/hyprland-plugin/{CMakeLists.txt,src,include,tests}
plugin-source/platform/viewflow-capture/{CMakeLists.txt,src,tests}
plugin-source/platform/hyprland-compat/
plugin-source/platform/reverse-common/
plugin-source/platform/window-recall/
bundle-manifest.json
```

源码目录保留相对 include 布局。包不包含中间构建目录。
manifest 的 `hyprland_variants` 列表代替旧的单个 `hyprland_build`：

```json
{
  "hyprland_variants": [{
    "line": "release",
    "version": "0.57.0",
    "commit": "0aa6745f705f2c4b0a5004eb019ef76e5bbdb426",
    "api_hash": "0aa6745f705f2c4b0a5004eb019ef76e5bbdb426_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6",
    "api_version": "0.2",
    "path": "plugins/release/0aa6745f705f2c4b0a5004eb019ef76e5bbdb426_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6"
  }]
}
```

示例 hash 对应本次构建环境。发行版如果修改构建依赖或源码，应记录其实际 hash。
CI 可以另外输出 `plugins/main/<api_hash>/`；默认桌面原生打包只生产 release 预构建。
`--payload` 接受带有 `hyprland-build.json` 的完整运行时 payload。
该文件必须含相同格式的 `hyprland_variants`，至少有一个 release 条目。
包检查逐项验证插件文件和 ELF 标记。
打包程序将源码与插件一起写入包清单的 SHA256 文件表。
Arch 打包器同样读取变体清单，并列出本地构建工具的可选依赖。

## 自动识别和本地构建

`platform/desktop-app/hyprland_plugins.py` 是 GUI 和冻结版 Linux autostart 共用的选择入口。

1. 读取 `hyprctl -j version` 的完整 commit、version、tag 和 `abiHash`。
2. 对旧 fork，如果缺少 `abiHash`，使用其 `buildAquamarine`、`buildHyprutils`、
   `buildHyprgraphics`、`buildHyprcursor`、`buildHyprlang` 重建相同 hash。
3. commit 和 API hash 均精确匹配时，选择包中的预构建。
4. 没有精确预构建时，查找同一 ABI 和源码摘要的本地构建缓存。
5. 没有缓存时，用 `pkg-config hyprland` 找到开发头文件。
6. 编译一个小探针，读取头文件的提交、API 版本及客户端 API hash。
7. 头文件和 compositor 的 commit/hash 均一致时，构建两个插件，再加载它们。

探针从安装的 `PluginAPI.hpp` 提取原始客户端 hash 函数，并包含 `version.h`。
它不链接 compositor，也不加载插件。
这避免包含完整 PluginAPI 时引入 compositor 全局构造函数造成未定义链接符号。
`CXX` 可以指定编译器。缺少工具或头文件时，错误说明所缺依赖并附编译器输出。
头文件不匹配时，错误同时显示运行 ABI 和头文件 ABI，并提示安装匹配头文件。
不得仅因用户属于其他 release、任意 main 提交或 fork 而拒绝构建。

缓存位置：

```text
${XDG_DATA_HOME:-$HOME/.local/share}/viewflow/plugins/<commit>/<sha256(api_hash+source_digest)[:24]>/
```

缓存含两个 `.so` 和实际构建元数据 `build.json`。
同级 `.lock` 文件用 `flock` 串行化 GUI/autostart 的并发构建。
源码或 ABI 改变时，选择新的缓存目录。
完整缓存无需再次调用编译器。首次构建使用两个并行任务，临时目录在结束后删除。
构建失败时保留同级 `.log`，不发布不完整缓存。
构建过程从不写入安装包目录。
PyInstaller 的私有库路径不传给宿主编译器或加载命令。

GUI 显示预构建、本地构建缓存或本地构建结果。
权限页区分“版本匹配”和“需要本地构建”，中文文案进入现有 i18n 字典。
本次修改不增加焦点、捕获新鲜度或时限限制。
加载动作仍由现有 GUI 操作或 autostart 启动流程触发。

## 构建和维护

准备 CMake、支持 C++23 的编译器、pkg-config、Hyprland 的开发依赖。
生成上游头文件还需要上游 CMake 的构建依赖和协议生成工具。
依赖不足时，在私有 prefix 构建依赖，并设置 `PKG_CONFIG_PATH`、`CMAKE_PREFIX_PATH`。
不得降低上游依赖版本检查来伪造构建通过。

```sh
# 仅更新对象数据库，不切换用户 checkout，不推送。
git -C /path/to/Hyprland fetch origin <release-commit> <main-commit>

python tools/build-hyprland-plugin-variants.py \
  --hyprland /path/to/Hyprland \
  --release <release-commit> --main <main-commit> \
  --output /tmp/viewflow-plugin-variants --jobs 2
```

脚本在独立临时 worktree 中配置上游 Hyprland，生成版本头文件和协议头文件。
它把头文件和 `.pc` 文件复制到私有 prefix。
**不要调用上游 `make installheaders`**：该规则还尝试写 `/usr/share/pkgconfig`。
脚本不安装 compositor、不执行系统安装、不运行 `hyprctl`。
随后它构建两个插件及其测试，并对每条线运行 CTest。
所有变体通过后才写输出元数据。
默认清理临时 worktree 和构建目录；`--keep-work` 保留它们并打印路径。
输出目录必须是新目录，失败时可以检查该目录及捕获的构建日志。

升级维护目标时：

1. 从 `origin` 确认上游 release 和 main 的完整提交。
2. 更新脚本的 `RELEASE` 和 `MAIN` 默认值。
3. 更新 `tools/build-desktop-app.py` 的默认 release 提交。
4. 使用新提交运行双线构建脚本。
5. 使用受支持 fork 的真实头文件补做两个插件的构建和 CTest。
6. 更新本页的固定目标和验证结果。

桌面原生打包必须使用 release 头文件。
`VIEWFLOW_HYPRLAND_RELEASE_COMMIT` 可以显式指定维护者的新 release 提交。
默认值不匹配时，打包程序在 Cargo 构建之前报错。
使用 `--keep-work` 可以保留 release 头文件，再把该 prefix 的 `share/pkgconfig`
放到 `PKG_CONFIG_PATH` 首位运行 `tools/build-desktop-app.py`。
一般的 main/fork 用户无需重新构建整个安装包，只需安装与运行 compositor 匹配的头文件。

## 验证结果（2026-11-01）

| 范围 | 结果 | 方法 |
|---|---|---|
| 上游 release 两个插件 | 已验证 | 真实生成头文件；CMake Release 构建；CTest 10 + 8 项通过 |
| 上游 main 两个插件 | 已验证 | 真实生成头文件；CMake Release 构建；CTest 10 + 8 项通过 |
| 本机 e5a03b6a5 fork 两个插件 | 已验证 | `/var/cache/hyprpm/wilf/headersRoot/share/pkgconfig`；CTest 10 + 8 项通过 |
| 桌面 Python 单元测试 | 已验证 | 82 项执行，80 项通过；2 项缺少原生验证包而跳过 |
| 选择与缓存分支 | 已验证 | 精确预构建、不同 commit/hash、fork hash、头文件不匹配、源码失效、失败不发布缓存 |
| 打包检查 | 已验证 | `tools/tests/unified-apps-test.py`，9 项通过；Windows 专用检查跳过 1 项 |
| autostart 配置回归 | 已验证 | `tools/tests/desktop-autostart-config-test.py` 通过，mock 检查；冻结版路径选择使用缓存结果 |
| 完整双线脚本入口 | 已验证 | 两条线各 18 项 CTest 通过；输出变体元数据；自动清理 worktree |
| 包内源码的实际本地构建 | 已验证 | 真正复制打包源码；使用 fork 头文件；第一次 `built`，第二次 `cached` |
| 完整桌面安装包 / PyInstaller 产物 | 未验证 | 本次验证插件和打包检查，未执行完整 Cargo/媒体/冻结打包 |
| 嵌套 compositor 加载 | 未验证 | 尝试构建 release compositor，在 6% 时停止可选构建；未启动嵌套实例 |
| 用户真实桌面加载和输入 | 未验证 | 任务禁止在真实会话运行 hyprctl；真实输入由用户操作 |

本次私有依赖为 hyprutils 0.14.3 和 hyprland-protocols 0.8.0。
其他构建依赖包括 Aquamarine 0.15.1、Hyprlang 0.6.8、Hyprgraphics 0.5.1、Hyprcursor 0.1.13。
这些版本来自真实构建环境，不是修改 `.pc` 文件得到的版本。
已有 `-Wsign-conversion` 和 `-Wmisleading-indentation` 警告仍存在；本次构建没有编译错误。

可复核日志及插件二进制保留在 `/tmp/viewflow-hyprvariants/`：

- `build.log`：两条上游线的头文件生成、构建和 CTest。
- `fork-build.log`：本机 fork 的构建和 CTest。
- `python-tests.log`、`packaging-tests.log`、`autostart-tests.log`：离线检查。
- `local-build.log`：实际本地构建与缓存选择结果。
- `ci.log`、`ci-output/`：完整双线脚本运行结果和按 ABI 分目录的产物。

源码构建证据不代表 compositor 加载成功。
本次没有运行用户会话的 `hyprctl`，没有加载或卸载用户插件。
本次没有停止服务、注入输入、改变焦点或写入用户安装目录。

持久化结果和产物 SHA256 见 [`evidence/hyprland-plugin-variants-20261101.json`](evidence/hyprland-plugin-variants-20261101.json)。
本次中间构建目录、私有依赖和临时 worktree 均已清理；保留证据约 8.3 MB。
