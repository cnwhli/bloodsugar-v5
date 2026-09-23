import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bloodsugar_v5/ui/chat/ai_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_secure_storage 在单测里没有原生实现：读 key 直接返回 null
  const ch = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async => null);
  });
  group('默认免费AI（零配置开箱即用）', () {
    test('全新安装：默认走免费在线AI且已启用', () async {
      SharedPreferences.setMockInitialValues({});
      final cfg = await AiAgentConfig.load();
      expect(cfg.enabled, true);
      expect(cfg.provider, AiProvider.pollinations);
      expect(cfg.baseUrl, isNotEmpty);
    });

    test('免费AI的chatUrl拼出OpenAI兼容地址', () async {
      SharedPreferences.setMockInitialValues({});
      final cfg = await AiAgentConfig.load();
      expect(cfg.chatUrl.startsWith('https://'), true);
      expect(cfg.chatUrl.endsWith('/openai'), true);
    });

    test('用户手动关闭过：尊重用户选择，不强行启用', () async {
      SharedPreferences.setMockInitialValues({'ai_enabled': false});
      final cfg = await AiAgentConfig.load();
      expect(cfg.enabled, false);
    });

    test('老用户已有Hermes配置：provider索引按+1迁移不漂移', () async {
      // 新enum：0=pollinations(新增默认)，老配置0=hermes→迁移后1
      expect(AiProvider.pollinations.index, 0);
      expect(AiProvider.hermes.index, 1);
      expect(AiProvider.openclaw.index, 2);
      expect(AiProvider.openaiCompat.index, 3);
    });

    test('老用户旧索引0（hermes）加载后仍是hermes', () async {
      SharedPreferences.setMockInitialValues({
        'ai_provider': 0, // 旧版存的hermes
        'ai_base_url': 'http://192.168.0.100:11438',
        'ai_enabled': true,
      });
      final cfg = await AiAgentConfig.load();
      expect(cfg.provider, AiProvider.hermes);
      expect(cfg.baseUrl, 'http://192.168.0.100:11438');
    });
  });
}
