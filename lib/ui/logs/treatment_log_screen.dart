import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/logs/treatment_log.dart';
import '../../domain/vitals/vital_types.dart';
import '../../services/health_bridge.dart';

/// 用药/打针记录页（对标欧态健康 App 的饮食/运动/用药/胰岛素日志）
///
/// 记录≠给药：这里只记"打了什么/吃了什么/做了什么"，不发任何指令到泵。
/// 首页"记一笔"按钮进入。类型：胰岛素 / 口服药 / 饮食 / 运动 / 备注。
class TreatmentLogScreen extends StatefulWidget {
  const TreatmentLogScreen({super.key});

  @override
  State<TreatmentLogScreen> createState() => _TreatmentLogScreenState();
}

class _TreatmentLogScreenState extends State<TreatmentLogScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _detailCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _extraCtrl = TextEditingController();
  String? _error;
  String _insulinUnit = 'U';
  String _site = '腹部';
  List<Map<String, dynamic>> _recent = [];
  HealthSnapshot _snap = const HealthSnapshot();
  bool _snapLoading = true;

  static const _types = ['insulin', 'medication', 'food', 'exercise', 'note'];

  static const _sites = ['腹部', '手臂', '大腿', '臀部'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _types.length, vsync: this);
    _reload();
    _loadSnapshot();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _detailCtrl.dispose();
    _amountCtrl.dispose();
    _extraCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await AppDatabase.init();
    final rows = await AppDatabase.instance.recentTreatments(limit: 30);
    if (!mounted) return;
    setState(() => _recent = rows);
  }

  /// 今日系统平台数据（有手表/手环自动带出来，点一下转成一条运动记录）
  Future<void> _loadSnapshot() async {
    final s = await HealthBridge.readTodaySnapshot();
    if (!mounted) return;
    setState(() {
      _snap = s;
      _snapLoading = false;
    });
  }

  String get _type => _types[_tabs.index];

  Future<void> _save() async {
    final detail = _detailCtrl.text.trim();
    final amount = double.tryParse(_amountCtrl.text.trim());
    final extra = _extraCtrl.text.trim();
    final t = _type;

    if (t == 'insulin') {
      if (detail.isEmpty) {
        setState(() => _error = '请填写胰岛素名称，如：门冬');
        return;
      }
      if (amount == null) {
        setState(() => _error = '请填写剂量（U）');
        return;
      }
      final err = checkInsulinDose(amount);
      if (err != null) {
        setState(() => _error = err);
        return;
      }
      await AppDatabase.instance.insertTreatment(
        type: t,
        detail: detail,
        amount: amount,
        unit: _insulinUnit,
        extra: _site,
      );
    } else if (t == 'medication') {
      if (detail.isEmpty) {
        setState(() => _error = '请填写药品名，如：二甲双胍');
        return;
      }
      await AppDatabase.instance.insertTreatment(
        type: t,
        detail: detail,
        amount: amount,
        unit: 'mg',
        extra: extra.isEmpty ? null : extra,
      );
    } else if (t == 'food') {
      if (detail.isEmpty) {
        setState(() => _error = '请填写吃了什么，如：螺蛳粉 1 碗');
        return;
      }
      await AppDatabase.instance.insertTreatment(
        type: t,
        detail: detail,
        extra: extra.isEmpty ? null : extra,
      );
    } else if (t == 'exercise') {
      if (detail.isEmpty && amount == null) {
        setState(() => _error = '请填写运动项目或分钟数');
        return;
      }
      await AppDatabase.instance.insertTreatment(
        type: t,
        detail: detail.isEmpty ? null : detail,
        amount: amount,
        unit: '分钟',
        extra: extra.isEmpty ? null : extra,
      );
    } else {
      if (detail.isEmpty) {
        setState(() => _error = '请填写备注内容');
        return;
      }
      await AppDatabase.instance.insertTreatment(type: t, detail: detail);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已记录')));
    _detailCtrl.clear();
    _amountCtrl.clear();
    _extraCtrl.clear();
    setState(() => _error = null);
    _reload();
  }

  /// 把系统平台的今日运动一键转成记录（免手填）
  Future<void> _importWorkout(WorkoutItem w) async {
    await AppDatabase.instance.insertTreatment(
      type: 'exercise',
      detail: workoutLabel(w.type),
      amount: w.minutes.toDouble(),
      unit: '分钟',
      extra: w.calories != null ? '约${w.calories} kcal（手表同步）' : '手表同步',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已记入：${workoutLabel(w.type)}')));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('记一笔'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          onTap: (_) => setState(() {
            _error = null;
          }),
          tabs: _types
              .map((t) => Tab(text: treatmentTypeLabel(t)))
              .toList(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildForm(),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('保存记录'),
                  ),
                  // 运动页：系统平台今日运动一键导入
                  if (_types[_tabs.index] == 'exercise') ...[
                    const SizedBox(height: 16),
                    _buildWatchImport(),
                  ],
                  const SizedBox(height: 16),
                  const Text('最近记录',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _buildRecent(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final t = _type;
    if (t == 'insulin') {
      return Column(
        children: [
          TextField(
            controller: _detailCtrl,
            decoration: const InputDecoration(
              labelText: '胰岛素名称',
              hintText: '如：门冬 / 甘精',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: '剂量（U）',
                    hintText: '如 6',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _site,
                  decoration: const InputDecoration(
                    labelText: '注射部位',
                    border: OutlineInputBorder(),
                  ),
                  items: _sites
                      .map((s) =>
                          DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _site = v ?? _site),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('只记录、不发指令到泵；单次最多 12U。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }
    if (t == 'medication') {
      return Column(
        children: [
          TextField(
            controller: _detailCtrl,
            decoration: const InputDecoration(
              labelText: '药品名',
              hintText: '如：二甲双胍',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: '剂量（mg，可空）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _extraCtrl,
                  decoration: const InputDecoration(
                    labelText: '备注（可空）',
                    hintText: '如：随餐',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
    if (t == 'food') {
      return Column(
        children: [
          TextField(
            controller: _detailCtrl,
            decoration: const InputDecoration(
              labelText: '吃了什么',
              hintText: '如：螺蛳粉 1 碗',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _extraCtrl,
            decoration: const InputDecoration(
              labelText: '备注（可空）',
              hintText: '如：餐后2h测',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          const Text('AI 助手可按食物名估 GI 和升糖，去问"吃了一碗螺蛳粉"。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }
    if (t == 'exercise') {
      return Column(
        children: [
          TextField(
            controller: _detailCtrl,
            decoration: const InputDecoration(
              labelText: '运动项目',
              hintText: '如：跑步 / 游泳 / 步行',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: '分钟数',
              hintText: '如 30',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      );
    }
    return TextField(
      controller: _detailCtrl,
      decoration: const InputDecoration(
        labelText: '备注',
        hintText: '如：熬夜 / 感冒',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _buildWatchImport() {
    if (_snapLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('正在读手表/手环今日数据…',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ),
      );
    }
    if (_snap.workouts.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('手表/手环今日暂无运动记录（需先在系统健康平台授权）。',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('手表今日运动（一键记入）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final w in _snap.workouts)
              Row(
                children: [
                  Expanded(
                    child: Text(
                        '${workoutLabel(w.type)} ${w.minutes}分钟${w.calories != null ? ' · ${w.calories}kcal' : ''}'),
                  ),
                  TextButton(
                    onPressed: () => _importWorkout(w),
                    child: const Text('记入'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecent() {
    if (_recent.isEmpty) {
      return const Text('还没有记录，上面记第一笔。',
          style: TextStyle(color: Colors.grey));
    }
    return Column(
      children: _recent.map((m) {
        final type = '${m['type'] ?? 'note'}';
        return Dismissible(
          key: ValueKey(m['id']),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) async {
            await AppDatabase.instance
                .deleteTreatment((m['id'] as num).toInt());
            _reload();
          },
          child: ListTile(
            dense: true,
            leading: Text(_typeIcon(type),
                style: const TextStyle(fontSize: 20)),
            title: Text(formatTreatment(
              type: type,
              detail: m['detail'] as String?,
              amount: (m['amount'] as num?)?.toDouble(),
              unit: m['unit'] as String?,
              extra: m['extra'] as String?,
            )),
            subtitle: Text(
                '${treatmentTypeLabel(type)} · ${_fmtTime('${m['recorded_at'] ?? ''}')}'),
          ),
        );
      }).toList(),
    );
  }

  String _typeIcon(String type) {
    switch (type) {
      case 'insulin':
        return '💉';
      case 'medication':
        return '💊';
      case 'food':
        return '🍜';
      case 'exercise':
        return '🏃';
      default:
        return '📝';
    }
  }

  String _fmtTime(String s) {
    try {
      final ts = DateTime.parse(s);
      return '${ts.month}月${ts.day}日 ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return s.length >= 16 ? s.substring(5, 16) : s;
    }
  }
}
