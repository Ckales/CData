// 临时垫片：子任务正在把结构页、服务器状态、用户管理从对话框拆成可嵌入的面板。
// 合并它们的改动时删掉这个文件，工作区直接用真正的面板。

import 'package:flutter/material.dart';

import 'data_source.dart';
import 'server_source.dart';
import 'server_status.dart';
import 'structure_view.dart';
import 'user_admin.dart';
import 'user_source.dart';

class StructurePanel extends StatelessWidget {
  final SchemaSource source;
  final String database;
  final String table;
  final VoidCallback? onAltered;

  const StructurePanel({super.key, required this.source, required this.database, required this.table, this.onAltered});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: OutlinedButton(
        onPressed: () => showTableStructure(context, source: source, database: database, table: table, onAltered: onAltered),
        child: Text('查看 $database.$table 的结构'),
      ),
    );
  }
}

class ServerStatusPanel extends StatelessWidget {
  final ServerSource source;
  final String serverLabel;

  const ServerStatusPanel({super.key, required this.source, required this.serverLabel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: OutlinedButton(
        onPressed: () => showServerStatus(context, source: source, serverLabel: serverLabel),
        child: const Text('服务器状态'),
      ),
    );
  }
}

class UserAdminPanel extends StatelessWidget {
  final UserSource source;

  const UserAdminPanel({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: OutlinedButton(onPressed: () => showUserAdmin(context, source: source), child: const Text('用户与权限')),
    );
  }
}
