// 冒烟测试：App 能启动。
// 注意：sqflite 在纯 Dart 测试环境不可用（databaseFactory 未初始化），
// 因此这里不启动完整 App，只验证核心 widget（WatchGlucoseTile）可渲染。
// 完整启动链路由 plugin 依赖（sqflite/bluetooth），属于集成测试范畴。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bloodsugar_v5/ui/watch/watch_glucose_tile.dart';

void main() {
  testWidgets('WatchGlucoseTile renders value and trend', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: WatchGlucoseTile(
              value: 6.7,
              trend: '→',
              statusColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    expect(find.text('6.7'), findsOneWidget);
    expect(find.text('→'), findsOneWidget);
  });

  testWidgets('WatchGlucoseTile high value renders', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: WatchGlucoseTile(
              value: 13.2,
              trend: '↑',
              statusColor: Colors.red,
            ),
          ),
        ),
      ),
    );

    expect(find.text('13.2'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
  });
}
