// 冒烟测试：App 能启动。
// 注意：sqflite 在纯 Dart 测试环境不可用（databaseFactory 未初始化），
// 因此这里不启动完整 App，只验证核心 widget（WatchGlucoseTile）可渲染。
// 完整启动链路由 plugin 依赖（sqflite/bluetooth），属于集成测试范畴。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bloodsugar_v5/ui/watch/watch_glucose_tile.dart';
import 'package:bloodsugar_v5/ui/watch/multi_watch_arch.dart';

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


  testWidgets('圆形表盘：内容被限制在圆的内切正方形内（约0.707×直径），四角不被裁切', (WidgetTester tester) async {
    // 固定一个 400×400 的圆形表盘尺寸
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatchAdaptiveLayout(
            shape: WatchShape.circular,
            child: SizedBox.expand(
              child: Container(key: const Key('inner')),
            ),
          ),
        ),
      ),
    );

    final innerSize = tester.getSize(find.byKey(const Key('inner')));
    // 内切正方形边长 = 400 × 0.7071 × 0.96 ≈ 271.4，减去默认 padding 8×2 ≈ 255.4
    expect(innerSize.width, greaterThan(250));
    expect(innerSize.width, lessThan(262));
    // 必须是正方形（宽高相等），且明显小于全屏 400（证明确实"调小"了）
    expect((innerSize.width - innerSize.height).abs(), lessThan(1));
    expect(innerSize.width, lessThan(400));
  });
}
