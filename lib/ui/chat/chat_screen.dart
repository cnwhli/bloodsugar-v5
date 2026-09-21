import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/datasource/local_db.dart';
import 'ai_agent_service.dart';

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
                      '问我血糖相关问题\n如：刚才测了 8.5 正常吗？\n低血糖怎么办？',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
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
                            color: m.me
                                ? Colors.blue[100]
                                : Colors.grey[200],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(m.text),
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
