import 'package:flutter/material.dart';
import '../../data/datasource/local_db.dart';
import 'ai_settings_screen.dart';

/// 个人中心：资料 + 目标范围 + AI 设置入口 + 数据导出
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _stats;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await AppDatabase.init();
      final stats = await AppDatabase.instance.weeklyStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _total = (stats['total'] as int?) ?? 0;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: const Text('糖友'),
              subtitle: Text('本周记录 $_total 条 · '
                  'TIR ${_stats?['tir'] ?? '--'}%'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy),
            title: const Text('AI 设置'),
            subtitle: const Text('连接 Hermes / OpenClaw / OpenAI 兼容网关'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const AiSettingsScreen()),
            ).then((_) => _load()),
          ),
          ListTile(
            leading: const Icon(Icons.show_chart),
            title: const Text('血糖报告'),
            subtitle: const Text('周统计 · TIR · 最高最低'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/report'),
          ),
          ListTile(
            leading: const Icon(Icons.family_restroom),
            title: const Text('家属远程查看'),
            subtitle: const Text('需配置 Supabase 后端（二期）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('家属功能需 Supabase，二期上线')),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于'),
            subtitle: const Text('血糖管家 V5.0 · GPLv3 开源 · 仅记录提醒，不做诊疗决策'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: '血糖管家',
              applicationVersion: '5.0.0',
              children: const [
                Text('多品牌 CGM 直连 + 手表表盘 + 糖友社区。\n数据存本机，云同步需自建 Supabase。')
              ],
            ),
          ),
        ],
      ),
    );
  }
}
