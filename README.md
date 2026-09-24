# CData

跨平台 MySQL 桌面客户端，macOS 与 Windows 通用。

Flutter 负责界面，Rust 负责全部数据库能力——连接、查询、类型解释、SQL 生成都在 Rust 核心里，
界面层不解释 MySQL 值也不拼 SQL。

> 早期开发中，尚不可用。

## 状态

已完成：

- 项目骨架（Flutter Desktop + Rust 核心 + flutter_rust_bridge）
- 类型保真层：MySQL 值 → 单元格值的无损映射

计划中：

- 连接管理（TCP / SSH 隧道 / SSL）、查询执行与流式读取
- 数据网格：虚拟滚动、区域选择、剪贴板、内联编辑
- SQL 编辑器：语法高亮、schema 感知补全
- 表结构查看与编辑、导入导出

## 设计取向

**不产出「假正确」的数据。** DECIMAL 不转浮点，`0000-00-00` 原样保留，文本列是否为二进制
由列元数据决定而不是靠猜编码，解码失败显式标记而不是替换成替代字符，NULL 和二进制内容在
界面上各有可辨认的占位而不是显示成空白。

宁可报错、宁可留白，也不拼一个看起来正常的值。

## 开发

需要 Flutter 3.47+、Rust 1.95+，macOS 端另需 Xcode 与 CocoaPods。

```bash
cd flutter_ui
flutter pub get
flutter run -d macos     # 或 -d windows
```

改了 Rust 侧的公开类型之后要重新生成 FFI 绑定（生成物已入库，普通构建不需要这步）：

```bash
cd flutter_ui && flutter_rust_bridge_codegen generate
```

### 测试

分三层，前两层不需要数据库：

```bash
cd crates/cdata-core && cargo test     # 核心逻辑
cd flutter_ui && flutter analyze
cd flutter_ui && flutter test          # 界面，喂内存数据
```

连真库的测试要先准备一个空库和几张表：

```sql
CREATE DATABASE cdata_test CHARACTER SET utf8mb4;
USE cdata_test;
SET SESSION sql_mode='';

-- 各种刁钻类型，验证读写不丢精度
CREATE TABLE type_zoo (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  big_unsigned BIGINT UNSIGNED, big_signed BIGINT,
  amount DECIMAL(20,4), ratio FLOAT, dbl DOUBLE,
  d_zero DATE, dt_micro DATETIME(6), t_neg TIME,
  txt_cn TEXT, vc VARCHAR(100), blob_col BLOB, vbin VARBINARY(64),
  json_col JSON, enum_col ENUM('draft','paid','refunded'), set_col SET('x','y','z'),
  bit_col BIT(8), tiny_bool TINYINT(1), nullable_txt VARCHAR(50)
);

-- 行数多，验证流式读取和虚拟滚动
CREATE TABLE big_rows (
  id INT UNSIGNED PRIMARY KEY, name VARCHAR(64) NOT NULL,
  amount DECIMAL(12,2) NOT NULL, created_at DATETIME NOT NULL,
  status TINYINT NOT NULL, note VARCHAR(200)
);

-- 编辑与拒绝规则
CREATE TABLE edit_target (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100), amount DECIMAL(12,2), note VARCHAR(200)
);
CREATE TABLE edit_composite (
  shop_id INT NOT NULL, order_no VARCHAR(32) NOT NULL,
  amount DECIMAL(12,2), PRIMARY KEY (shop_id, order_no)
);
CREATE TABLE no_pk (a INT, b VARCHAR(50));
```

> 造中文测试数据时客户端要带 `--default-character-set=utf8mb4`。有些 MySQL 发行版的
> `character_set_client` 默认是 latin1，会把 UTF-8 字节双编码存进去，而读取时又反向转一次，
> **在命令行里完全看不出来**，只有按 utf8mb4 读的客户端才会看到乱码。

测试会自己在测试库里建几张探针表（`CREATE TABLE IF NOT EXISTS`，只增不删）：表结构查看用 `structure_parent` / `structure_child`，
结构编辑用 `alter_probe_*`（跑完结构改回原样），导入用 `import_probe`（跑完按批次标记删掉本次写入的行）。

连接信息通过环境变量传，不写进代码：

```bash
export CDATA_TEST_HOST=127.0.0.1
export CDATA_TEST_PORT=3306
export CDATA_TEST_USER=<user>
export CDATA_TEST_PASSWORD=<password>
export CDATA_TEST_DB=cdata_test

cd crates/cdata-core && cargo test          # 真库测试，没配环境变量就自动跳过
cd flutter_ui && ./run_integration_tests.sh # FFI 链路 + 端到端冒烟
```

`run_integration_tests.sh` 还会把主界面导出成 `flutter_ui/build/shots/main.png`。

## 许可

MIT
