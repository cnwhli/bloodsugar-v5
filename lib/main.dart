import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:bloodsugar_v5/services/bg_sync.dart';
import 'package:health/health.dart';
import 'package:bloodsugar_v5/ui/dashboard/dashboard_screen.dart';
import 'package:bloodsugar_v5/ui/ble/ble_scanner_screen.dart';
import 'package:bloodsugar_v5/ui/ble/cgm_foreground_service.dart';
import 'package:bloodsugar_v5/ui/ble/glucose_overlay.dart' show overlayMain;
import 'package:bloodsugar_v5/ui/ble/manual_entry_screen.dart';
import 'package:bloodsugar_v5/ui/logs/treatment_log_screen.dart';
import 'package:bloodsugar_v5/ui/report/report_screen.dart';
import 'package:bloodsugar_v5/ui/ble/dose_confirmation_screen.dart';
import 'package:bloodsugar_v5/ui/ble/manual_bolus_screen.dart';
import 'package:bloodsugar_v5/ui/watch/watch_glucose_page.dart';
import 'package:bloodsugar_v5/ui/chat/chat_screen.dart';
import 'package:bloodsugar_v5/ui/community/wechat_group_screen.dart';
import 'package:bloodsugar_v5/ui/profile/profile_screen.dart';
import 'package:bloodsugar_v5/ui/profile/alert_settings_screen.dart';
import 'package:bloodsugar_v5/services/rag_service.dart';
import 'package:bloodsugar_v5/services/cloud_sync.dart';
import 'package:bloodsugar_v5/domain/bluetooth/pump_pairing.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 前台服务通信端口（后台 isolate 收数 → 主 isolate 入库/刷新 UI）
  FlutterForegroundTask.initCommunicationPort();
  // 后台 isolate 收数 → 主 isolate 刷新 UI（dashboard/蓝牙页/手表页都订阅 BgSync）
  FlutterForegroundTask.addTaskDataCallback(bgTaskCallback);
  // 云同步：本机存过 url+key 才初始化（没配过就是纯本机模式，不挡启动）
  try {
    await CloudSync.initFromStorage();
  } catch (_) {}
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const BloodSugarApp());
}

/// 应用主题配置
class AppTheme {
  /// 主色 - 医疗蓝
  static const Color primary = Color(0xFF0A84FF);

  /// 安全绿（正常血糖）
  static const Color safeGreen = Color(0xFF34C759);

  /// 警告蓝（低血糖）
  static const Color warnBlue = Color(0xFF5AC8FA);

  /// 危险红（高血糖）
  static const Color dangerRed = Color(0xFFFF3B30);

  /// 背景色
  static Color backgroundColor(bool isDark) =>
      isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);

  /// 卡片背景
  static Color cardColor(bool isDark) =>
      isDark ? const Color(0xFF2C2C2E) : Colors.white;

  /// 获取完整主题
  static ThemeData lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ),
    useMaterial3: true,
    fontFamily: 'PingFang SC',
    cardTheme: CardThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
  );

  static ThemeData darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    fontFamily: 'PingFang SC',
    cardTheme: CardThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
  );
}

class BloodSugarApp extends StatelessWidget {
  const BloodSugarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '血糖管家',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const MainTabView(),
      routes: {
        '/ble': (context) => const BleScannerScreen(),
        '/add': (context) => const ManualEntryScreen(),
        '/log': (context) => const TreatmentLogScreen(),
        '/report': (context) => const ReportScreen(),
        '/dose': (context) => DoseConfirmationScreen(
              suggestion: DoseSuggestion(
                bolusUnits: 0,
                reason: '测试',
                safe: true,
                safetyNote: '',
              ),
              onConfirm: () {},
              onCancel: () => Navigator.pop(context),
            ),
        '/pump-pair': (context) => PumpPairScreen(brand: PumpBrand.danaR),
        '/manual-bolus': (context) => const ManualBolusScreen(),
        '/community': (context) => const WechatGroupScreen(),
        '/ai-assistant': (context) => const AiHealthAssistantScreen(),
        '/alert-settings': (context) => const AlertSettingsScreen(),
        // 自研表盘页：手机可预览；OPPO Watch X 装同包打开即用，可脱离手机独立监听
        '/watch': (context) =>
            const WatchGlucosePage(userId: 'default_user'),
      },
    );
  }
}

class MainTabView extends StatefulWidget {
  const MainTabView({super.key});

  @override
  State<MainTabView> createState() => _MainTabViewState();
}

class _MainTabViewState extends State<MainTabView> {
  int _index = 0;
  final _pages = const [
    DashboardScreen(),
    BleScannerScreen(),
    ChatScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack：4 个 tab 页常驻不销毁——蓝牙监听、列表、订阅切页不断，
      // 之前切页即 dispose 是"切页丢数据"的病根之一
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: '首页'),
          NavigationDestination(icon: Icon(Icons.bluetooth), label: '蓝牙'),
          NavigationDestination(icon: Icon(Icons.chat), label: 'AI 助手'),
          NavigationDestination(icon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }
}