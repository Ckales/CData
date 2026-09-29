# CData

CData 是面向 macOS 和 Windows 的 MySQL 桌面客户端。可以管理连接、执行 SQL、查看与编辑表数据。

**[下载最新版本](https://github.com/Ckales/CData/releases/latest)** · [反馈问题](https://github.com/Ckales/CData/issues)

## 下载与安装

- **macOS**：下载 `.dmg`，打开后将 `CData.app` 拖入“应用程序”。如果系统提示无法验证开发者，请确认文件来自本项目 Releases，再到“系统设置 → 隐私与安全性”允许打开。
- **Windows**：下载 Windows `.zip` 并完整解压，在 `CData` 文件夹中运行 `CData.exe`。运行时需要压缩包内的其他文件。

## 功能

- 通过 TCP、SSL 或 SSH 隧道连接 MySQL；连接配置可保存，密码和 SSH 口令保存在系统凭据存储中。
- 浏览数据库和表、执行 SQL、查看与编辑表结构，以及管理数据库用户。
- 在数据网格中查看和编辑记录；导入 CSV、SQL，导出 CSV、SQL。
- 保留 DECIMAL 精度和零日期原文；NULL、二进制及无效文本有明确区分。

Flutter 负责界面，Rust 核心处理数据库连接、查询与 MySQL 值。项目采用 [MIT 许可证](LICENSE.md)。
