# 企业微信 Linux 版（deepin-wine）：内嵌网页无法打开修复

解决 deepin-wine 版企业微信的群公告、在线文档、邮件等内嵌网页无法打开、空白或展示异常的问题，并兼顾字体和更新兼容性。

## 修复方案

以 deepin 官方企微的完整运行环境为基座，而不是重新创建空 Wine 容器：

1. 从官方企微 deb 提取 `files.7z`、`files/dlls/`、启动配置和图形探测程序，保留容器内的 Windows 组件、运行库及注册表。
2. 在官方容器中安装腾讯官方新版 EXE。
3. 以配套原版 Wine 为底，**仅额外覆盖 `lib/wine/i386-windows/kernelbase.dll`**，使用官方企微包中的定制版本。
4. 保留官方 `WINEPREDLL` 与完整 `files/dlls/`；“单模块覆盖”不是移除官方预加载环境。
5. 补齐文泉驿微米黑字体文件及字体登记，保留官方已有字体替换规则，不改 DPI。
6. 提供原版 `kernelbase` 的更新兼容入口，避免为更新永久关闭内嵌网页修复。

详见 [解决方案](docs/02-解决方案.md)和[问题原因](docs/01-问题原因.md)。

## 验证与限制

本机环境：Debian 13、GNOME / Wayland、XWayland、Intel 核显。

| 项目 | 状态 |
|---|---|
| 官方容器升级到 5.0.13.6005、仅额外使用定制 i386 `kernelbase.dll` | 隔离对照中群公告正常；以文件哈希和 `/proc/<pid>/maps` 确认加载来源 |
| 本次异常的具体 Wine/CEF 内部调用原因 | 未逆向到函数级；本轮日志没有复现历史 `CreateWindowEx Error = 1400`，不将两次现象混为一个证据 |
| 邮件、在线文档及其他内嵌页面 | 尚未逐项验收 |
| 字体 | 字体文件和注册表登记已在独立前缀验证；视觉效果待桌面确认 |
| 在线更新 | 历史记录显示定制 i386 `kernelbase` 可能导致 `EINVAL`；保留原版引擎入口，新组合在线更新仍待验证 |
| 最终 deb 的安装、升级和卸载 | 以当前构建日志和产物检查结果为准；脚本测试不等于桌面验收 |

不把历史 `CreateWindowEx`、整套模块覆盖或在线更新结果直接外推到当前组合。其他发行版、桌面或新版本材料都需重新验证。

## 构建

材料准备、命令用法、缺失材料的自动下载与缓存、日志及产物检查见[构建流程](docs/03-构建流程.md)。

## 安装与运行

以下是修订脚本的目标使用方式；使用前应确认 deb 确实由修订脚本构建并完成验收，旧 Release 不能据此视为已更新。

```bash
sha256sum -c com.qq.weixin.work.deepin_5.0.13.6005_amd64.deb.sha256
```

```bash
sudo apt install ./com.qq.weixin.work.deepin_5.0.13.6005_amd64.deb
```

- `~/.deepinwine/WXWork-official-bundled`：首次启动部署的独立官方前缀；卸载软件包不会自动删除用户数据。

- **日常入口**：修复内嵌网页，使用定制 32 位 `kernelbase`。
- **右键“更新兼容模式”**：使用原版 `kernelbase`。内嵌网页可能不可用，在线更新仍需验证；完成后从托盘完全退出，再从日常入口重开。
- **本地官方 EXE 安装**：先退出企微，再用显式安装参数，避免把安装包误传给客户端。

```bash
/opt/apps/com.qq.weixin.work.deepin/files/run.sh --install "$HOME/Downloads/WeCom_5.0.13.6005_200003.exe"
```

该命令使用原版更新引擎和现有兼容前缀，不代表任意新版 EXE 均已验证。不要用 sudo 运行客户端或安装器，不要同时打开两个模式。

日志位置、双入口、已有容器保护和字体说明见 [解决方案](docs/02-解决方案.md)。

## 目录

```text
.ready/                   本地构建材料（不提交）
build/                    构建产物；仅同版本旧产物移入 backup/
build/backup/             同版本历史 .deb 和 .sha256
build/.middle-file/       构建中间文件；成功后清理，失败时保留
build/.build.lock         防止并行构建
.logs/                    构建日志；关键节点带本地时间戳
scripts/                  构建、启动、模板处理与日志解密脚本
packaging/                deb 元数据、菜单、字体登记配置
packaging/DEBIAN/         deb 安装、卸载脚本及控制信息
tests/                    不依赖真实账号的脚本测试
docs/                     原因、方案、构建流程、日志与排查记录
```

运行脚本测试：

```bash
python3 -I tests/test_runtime.py -v
```

## 来源与许可

- Wine：deepin 官方应用商店 `deepin-wine10-stable 10.14deepin14`，基于 Wine（LGPL-2.1+）。
- 官方容器、定制模块和程序资源：`com.qq.weixin.work.deepin 5.0.10.6015deepin3`。
- GL 辅助组件：官方 `deepin-wine-helper 5.4.10-1`。
- 字体：Debian 官方 `fonts-wqy-microhei`（Apache-2.0 / GPLv3）。
- 企业微信 EXE：腾讯官方发布；仓库不包含上述大型二进制文件。

本项目非腾讯或统信官方项目，未获得其授权或认可。软件、字体、图标和商标的权利归各自权利人；沿用包名不代表官方发布。安装包仅用于个人测试，不收费，不包含破解、去广告、绕过授权或收集数据的功能；使用前应遵守相关许可及所在单位规定。

按“现状”提供，无任何明示或暗示保证；使用者需自行保护账号和数据。日志可能包含企业、联系人和账号信息，不要上传解密日志或含账号的容器。相关权利人可通过 Issue 联系处理。

## 赞赏

如果这个仓库对您有用，可以点个 star 或使用微信扫描赞赏码。
<img width="595" height="569" alt="85a452b916f05293884a7d19f2933f36" src="https://github.com/user-attachments/assets/665807c4-8126-47c0-9d46-779427467364" />

