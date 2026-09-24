import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../data/datasource/local_db.dart';
import '../../services/cloud_sync.dart';
import 'ai_agent_service.dart';
import 'chat_log_parser.dart';

/// AI 助手聊天页
///
/// 数据源三档（按可用性自动降级）：
/// 1. 云端 AI Agent（Hermes / OpenClaw / 兼容 OpenAI 的网关）— 配了地址就有RAG+工具
/// 2. 本地规则引擎（离线可用）— 血糖解读 + 饮食运动建议
/// 3. 未配置时引导去"我的 → AI 设置"填写
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatMsg {
  final bool me;
  final String text;
  _ChatMsg(this.me, this.text);
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatMsg> _msgs = [];
  bool _busy = false;
  String _mode = '';

  @override
  void initState() {
    super.initState();
    _refreshMode();
  }

  Future<void> _refreshMode() async {
    final cfg = await AiAgentConfig.load();
    if (!mounted) return;
    setState(() => _mode = cfg.enabled ? '云端 ${cfg.providerLabel}' : '本地模式');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _msgs.add(_ChatMsg(true, q));
      _ctrl.clear();
      _busy = true;
    });
    _scrollToBottom();

    String reply;
    try {
      // 取最近一条血糖做上下文
      double? latest;
      try {
        await AppDatabase.init();
        final rows = await AppDatabase.instance.recentReadings(limit: 1);
        if (rows.isNotEmpty) {
          latest = (rows.first['value_mmol_l'] as num?)?.toDouble();
        }
      } catch (_) {}
      reply = await AiAgentService().ask(q, currentGlucoseMmolL: latest);
      await _refreshMode();
    } catch (e) {
      reply = '出错了：$e';
    }
    if (!mounted) return;
    setState(() {
      _msgs.add(_ChatMsg(false, reply));
      _busy = false;
    });
    _scrollToBottom();
    // 对话记一笔：用户原话里有饮食/用药/心率意图 → 弹窗确认后落库
    final drafts = parseLogIntent(q);
    if (drafts.isNotEmpty && mounted) _confirmAndSave(drafts);
  }

  /// 记账确认弹窗：逐条列出识别结果，点"确认记下"才入库+推云；
  /// 点"不对"直接丢弃。安全线：只做记录，不做任何剂量建议。
  Future<void> _confirmAndSave(List<DraftRecord> drafts) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('记一笔？', style: TextStyle(fontSize: 20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('刚才说的，识别成这几条记录：',
                style: TextStyle(fontSize: 15, color: Colors.grey)),
            const SizedBox(height: 8),
            for (final d in drafts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      d.isVital
                          ? Icons.favorite
                          : d.kind == 'insulin'
                              ? Icons.medication
                              : d.kind == 'food'
                                  ? Icons.restaurant
                                  : d.kind == 'exercise'
                                      ? Icons.directions_run
                                      : Icons.note_alt,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(d.label,
                          style: const TextStyle(fontSize: 17)),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不对', style: TextStyle(fontSize: 16)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认记下', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var n = 0;
    try {
      await AppDatabase.init();
      for (final d in drafts) {
        final now = DateTime.now();
        if (d.isVital) {
          final id = await AppDatabase.instance.insertVital(
            kind: d.kind,
            value1: d.amount,
            unit: d.unit ?? '',
            source: 'manual',
            device: d.extra,
            recordedAt: now,
          );
          await CloudSync.pushVital(
            localId: id,
            kind: d.kind,
            value1: d.amount,
            unit: d.unit ?? '',
            source: 'manual',
            device: d.extra,
            measuredAt: now,
          );
        } else {
          final id = await AppDatabase.instance.insertTreatment(
            type: d.kind,
            detail: d.detail,
            amount: d.amount,
            unit: d.unit,
            extra: d.extra,
            recordedAt: now,
          );
          await CloudSync.pushTreatment(
            localId: id,
            type: d.kind,
            detail: d.detail ?? '',
            amount: d.amount,
            unit: d.unit ?? '',
            extra: d.extra,
            measuredAt: now,
          );
        }
        n++;
      }
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(n > 0 ? '已记下 $n 条' : '记录失败，再试一次')),
    );
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 健康助手'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(_mode, style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? const Center(
                    child: Text(
                      '问我血糖相关问题\n如：刚才测了 8.5 正常吗？\n低血糖怎么办？\n\n也能直接记一笔：\n吃了两碗米饭 / 打了6U / 心跳95',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16, height: 1.8),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _msgs.length,
                    itemBuilder: (context, i) {
                      final m = _msgs[i];
                      return Align(
                        alignment: m.me
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.of(context).size.width * 0.8,
                          ),
                          decoration: BoxDecoration(
                            // 深色底+白字 / 浅色底+黑字：对比度拉满，急诊医嘱也看得清。
                            // 之前硬编码 blue[100]/grey[200]，深色模式下白字压浅底=隐形。
                            color: m.me
                                ? const Color(0xFF1565C0)
                                : (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? const Color(0xFF2A2A2A)
                                    : Colors.white),
                            borderRadius: BorderRadius.circular(12),
                            border: m.me
                                ? null
                                : Border.all(
                                    color: Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? const Color(0xFF444444)
                                        : const Color(0xFFE0E0E0),
                                  ),
                          ),
                          // AI 回答走 Markdown 渲染：**加粗**、列表正常显示，不再露源码
                          child: m.me
                              ? Text(
                                  m.text,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      height: 1.5,
                                      color: Colors.white),
                                )
                              : MarkdownBody(
                                  data: m.text,
                                  selectable: true,
                                  styleSheet: MarkdownStyleSheet(
                                    p: TextStyle(
                                      fontSize: 16,
                                      height: 1.6,
                                      color: Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                    strong: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white
                                          : Colors.black,
                                    ),
                                    listBullet: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('思考中…', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: '输入问题…',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
