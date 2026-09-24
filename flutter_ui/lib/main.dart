import 'package:flutter/material.dart';

import 'query_page.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const CDataApp());
}

class CDataApp extends StatelessWidget {
  const CDataApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CData',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const QueryPage(),
    );
  }
}
