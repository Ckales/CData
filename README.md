# CData

CData 是面向 macOS 和 Windows 的 MySQL 桌面客户端。可以管理连接、执行 SQL、查看与编辑表数据。

**[下载最新版本](https://github.com/Ckales/CData/releases/latest)** · [反馈问题](https://github.com/Ckales/CData/issues)

## 下载与安装

- **macOS**：下载 `.dmg`，打开后将 `CData.app` 拖入“应用程序”。如果系统提示无法验证开发者，请确认文件来自本项目 Releases，再到“系统设置 → 隐私与安全性”允许打开。
- **Windows**：下载 `CData-版本号-windows-x64-setup.exe`，运行安装向导。默认安装到当前用户目录，无需管理员权限；安装后从开始菜单启动，也可选择创建桌面快捷方式。在 Windows“设置 → 应用”中可卸载，后续版本运行安装包即可覆盖升级。

## 功能

- 通过 TCP、SSL 或 SSH 隧道连接 MySQL；连接配置可保存，密码和 SSH 口令保存在系统凭据存储中。
- 浏览数据库和表、执行 SQL、查看与编辑表结构，以及管理数据库用户。
- 在数据网格中查看和编辑记录；导入 CSV、SQL，导出 CSV、SQL。
- 保留 DECIMAL 精度和零日期原文；NULL、二进制及无效文本有明确区分。

Flutter 负责界面，Rust 核心处理数据库连接、查询与 MySQL 值。项目采用 [MIT 许可证](LICENSE.md)。

## Windows 安装包构建

在 Windows 安装 Flutter、Rust、Visual Studio C++ 桌面开发工具及 Inno Setup 6.5+，然后运行：

```powershell
cd flutter_ui
flutter build windows --release
pwsh -File tool/package_windows.ps1
```

安装包输出到仓库根目录的 `dist`，版本读取自 `pubspec.yaml`，包含完整 Flutter 产物和 x64 Visual C++ 运行库。
安装器使用固定应用标识，后续版本沿用安装路径；卸载保留用户配置、历史和系统凭据。
标签发布流程会生成安装包，并在上传前执行静默安装、文件内容比对和卸载检查；安装向导交互及跨版本升级需在 Windows 真机验收。
