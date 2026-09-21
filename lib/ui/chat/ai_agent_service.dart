/// AI Agent 接入层：Hermes / OpenClaw / 任意 OpenAI 兼容网关
///
/// 为什么这样设计：
/// - Hermes Agent 自带 OpenAI 兼容代理（`hermes proxy`）：手机 App 只要会调
///   OpenAI /chat/completions 接口，就能连上用户自己电脑上的 Hermes，
///   复用用户已配好的模型和 key，血糖数据不出内网。
/// - OpenClaw 同理：跑起来后暴露 OpenAI 兼容端点，填地址就能用。
/// - 都没配时走本地规则引擎（离线可用）：血糖解读 + 低血糖急救 + 饮食运动建议。
/// - 全程不内置任何 key：地址和 key 存在用户手机本地（SharedPreferences，
///   key 放 flutter_secure_storage），卸载即删。
///
/// 配置入口："我的 → AI 设置"（AiSettingsScreen）。

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Agent 提供方
enum AiProvider {
  hermes('Hermes Agent（hermes proxy）', '/v1/chat/completions'),
  openclaw('OpenClaw（OpenAI 兼容端点）', '/v1/chat/completions'),
  openaiCompat('自定义 OpenAI 兼容网关', '/v1/chat/completions');

  final String label;
  final String chatPath;
  const AiProvider(this.label, this.chatPath);
}

/// 连接配置（本地持久化）
class AiAgentConfig {
  static const _kEnabled = 'ai_enabled';
  static const _kProvider = 'ai_provider';
  static const _kBaseUrl = 'ai_base_url';
  static const _kModel = 'ai_model';
  static const _kApiKey = 'ai_api_key'; // secure storage

  static const _secure = FlutterSecureStorage();

  bool enabled;
  AiProvider provider;
  String baseUrl; // 如 http://192.168.0.100:11438
  String model; // 如 default / claude-opus-5 / gpt-4o
  String apiKey; // 可空（内网网关常不需要）

  AiAgentConfig({
    this.enabled = false,
    this.provider = AiProvider.hermes,
    this.baseUrl = '',
    this.model = 'default',
    this.apiKey = '',
  });

  String get providerLabel => provider.label;

  String get chatUrl {
    var base = baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return '$base${provider.chatPath}';
  }

  static Future<AiAgentConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final cfg = AiAgentConfig(
      enabled: prefs.getBool(_kEnabled) ?? false,
      baseUrl: prefs.getString(_kBaseUrl) ?? '',
      model: prefs.getString(_kModel) ?? 'default',
    );
    final pIdx = prefs.getInt(_kProvider) ?? 0;
    cfg.provider = AiProvider.values[pIdx.clamp(0, AiProvider.values.length - 1)];
    cfg.apiKey = await _secure.read(key: _kApiKey) ?? '';
    if (cfg.baseUrl.isEmpty) cfg.enabled = false;
    return cfg;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    await prefs.setInt(_kProvider, provider.index);
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kModel, model);
    if (apiKey.isEmpty) {
      await _secure.delete(key: _kApiKey);
    } else {
      await _secure.write(key: _kApiKey, value: apiKey);
    }
  }
}

/// 统一问答入口
class AiAgentService {
  static final AiAgentService _instance = AiAgentService._internal();
  factory AiAgentService() => _instance;
  AiAgentService._internal();

  static const _systemPrompt = '''你是血糖管家的健康助手，面向中国糖友，用中文回答。
规则：只做健康科普和用药提醒，不做诊断、不开处方；涉及调药、胰岛素剂量必须提示咨询医生；
血糖 <3.9 提示按 15-15 原则处理并就医；回答简短，重点先行。''';

  /// 问答：云端优先，失败/未配置自动降级本地规则
  Future<String> ask(String question, {double? currentGlucoseMmolL}) async {
    final cfg = await AiAgentConfig.load();
    if (cfg.enabled && cfg.baseUrl.isNotEmpty) {
      try {
        return await _askCloud(cfg, question, currentGlucoseMmolL);
      } catch (e) {
        return '${_askLocal(question, currentGlucoseMmolL)}\n\n（云端助手连接失败：$e，已用本地模式回答）';
      }
    }
    return _askLocal(question, currentGlucoseMmolL);
  }

  Future<String> _askCloud(
      AiAgentConfig cfg, String question, double? glucose) async {
    var context = '';
    if (glucose != null && glucose > 0) {
      context = '（用户当前血糖 ${glucose.toStringAsFixed(1)} mmol/L）';
    }
    final body = jsonEncode({
      'model': cfg.model.isEmpty ? 'default' : cfg.model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': '$question$context'},
      ],
      'temperature': 0.3,
      'max_tokens': 800,
    });
    final headers = {'Content-Type': 'application/json'};
    if (cfg.apiKey.isNotEmpty) headers['Authorization'] = 'Bearer ${cfg.apiKey}';
    final resp = await http
        .post(Uri.parse(cfg.chatUrl), headers: headers, body: body)
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}：${resp.body}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) throw Exception('网关返回为空');
    final text = (choices.first as Map)['message']?['content']?.toString().trim();
    if (text == null || text.isEmpty) throw Exception('网关返回为空');
    return text;
  }

  /// 本地规则引擎（离线可用）
  String _askLocal(String question, double? glucose) {
    final q = question.toLowerCase();
    final g = glucose != null && glucose > 0
        ? '\n你当前血糖 ${glucose.toStringAsFixed(1)} mmol/L。'
        : '';

    bool has(List<String> keys) => keys.any(q.contains);

    if (has(['低', 'hypo', '<3.9', '3.9', '头晕', '心慌', '出汗'])) {
      return '低血糖（<3.9 mmol/L）按 15-15 原则：吃 15g 快速碳水（葡萄糖片/果汁/糖果），15 分钟后复测，仍低重复一次。意识不清不要喂食，立即就医。$g';
    }
    if (has(['正常', '范围', '标准', '目标', '高吗', '正常吗'])) {
      var s = '参考范围：空腹 3.9–6.1，餐后2h <7.8；动态血糖目标 TIR（3.9–10.0）>70%。';
      if (glucose != null && glucose > 0) {
        s += glucose < 3.9
            ? '你当前偏低，按低血糖处理。'
            : glucose > 10.0
                ? '你当前偏高，多喝水、避免剧烈运动后先复测，持续高联系医生。'
                : '你当前在目标范围内。';
      }
      return s;
    }
    if (has(['吃', '饮食', '食物', 'gi', '碳水', '米饭', '水果'])) {
      return '饮食要点：定时定量、优选低GI（杂粮/蔬菜/蛋白先吃）、水果两餐之间少量、饮酒前先测血糖。$g';
    }
    if (has(['运动', '跑步', '锻炼', '走路'])) {
      return '运动建议：每周150分钟中等强度有氧；运动前测血糖，<5.6 先加餐；随身带快速碳水；避免空腹运动。$g';
    }
    if (has(['胰岛素', '打针', '剂量', '泵', '大剂量'])) {
      return '用药提醒：剂量调整务必遵医嘱；本 App 只做记录和提醒，不做剂量决策；胰岛素未开封 2–8°C，开封室温 28 天。$g';
    }
    if (has(['夜', '睡', '黎明', '苏木杰'])) {
      return '夜间血糖：睡前测一次，设低血糖闹钟；晨起偏高可能是黎明现象或夜间低血糖反跳，建议做几天 0/3/6 点血糖谱给医生看。$g';
    }
    return '收到：$question$g\n\n本地模式只能做基础科普。连上 Hermes/OpenClaw 后我可以结合你的血糖曲线做个性化分析，去"我的 → AI 设置"配置。';
  }

  /// 连通性测试
  Future<String> testConnection(AiAgentConfig cfg) async {
    try {
      final r = await _askCloud(cfg, '回一个"连接正常"即可', null);
      return '连接正常：$r';
    } catch (e) {
      return '连接失败：$e';
    }
  }
}
