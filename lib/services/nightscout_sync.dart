/// Nightscout 上传（https://nightscout.github.io/ API v1，MIT 兼容自研实现）。
///
/// 家属远程看的标准通道：entries（血糖点）+ treatments（泵/校正备注，
/// 本 App 只写 entries；sendBolus 已锁死抛错，treatments 只读展示用）。
/// 两个配置存 SharedPreferences：ns_url（如 https://xxx.herokuapp.com，
/// 尾斜杠自动去）、ns_secret（API_SECRET 明文，用户自己服务器的密码）。
/// 每条血糖入库写 HealthBridge 后顺手调 NightscoutSync.push，一条 POST，
/// 失败静默（家属看晚几分钟不碍事，不挡主流程）。
library;

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

class NightscoutSync {
  static const _kUrl = 'ns_url';
  static const _kSecret = 'ns_secret';

  /// 是否配好（两项都有才传）
  static Future<bool> get isConfigured async {
    final p = await SharedPreferences.getInstance();
    final u = (p.getString(_kUrl) ?? '').trim();
    final s = (p.getString(_kSecret) ?? '').trim();
    return u.isNotEmpty && s.isNotEmpty;
  }

  static Future<void> save(String url, String secret) async {
    final p = await SharedPreferences.getInstance();
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    await p.setString(_kUrl, u);
    await p.setString(_kSecret, secret.trim());
  }

  static Future<(String, String)> load() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_kUrl) ?? '', p.getString(_kSecret) ?? '');
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kUrl);
    await p.remove(_kSecret);
  }

  /// 推一条血糖。mgDl 整数，time  UTC 时间，device 固定 'bloodsugar-v5'。
  /// 失败静默返回 false（调用方不用管）。
  static Future<bool> push({
    required double mgDl,
    required DateTime time,
    String device = 'bloodsugar-v5',
  }) async {
    try {
      final (base, secret) = await load();
      if (base.isEmpty || secret.isEmpty) return false;
      final token = sha1.convert(secret.codeUnits).toString();
      final uri = Uri.parse('$base/api/v1/entries?token=$token');
      final body = jsonEncode([
        {
          'type': 'sgv',
          'sgv': mgDl.round(),
          'date': time.toUtc().millisecondsSinceEpoch,
          'dateString': time.toUtc().toIso8601String(),
          'device': device,
        }
      ]);
      final resp = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 15));
      return resp.statusCode == 200 || resp.statusCode == 201;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
