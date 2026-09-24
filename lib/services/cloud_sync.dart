import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/datasource/local_db.dart';

/// 云同步：Supabase 账号登录 + 血糖/vitals/treatments 双向同步 + Realtime 订阅。
///
/// 设计（配合 supabase_schema.sql）：
/// - key 存本机安全存储，不进代码不进仓库；
/// - 云端 id = 本地自增 id 拼串（r/v/t 前缀），手机/手表/换设备同一条同一个 id，
///   upsert 天然去重，不翻倍；
/// - 上传：登录后每次新数进来调 pushReading/pushVital/pushTreatment（失败吞掉，
///   下次整量同步时补——断网不丢）；
/// - 下拉：syncAll 拉云端全量，按（时间+值）/（kind+时间）本地判重补缺；
/// - 互通：subscribeRealtime 订阅三表 INSERT，手机/手表一方上传另一方秒级收到
///   → 回调里入库 + 刷新 UI（手表连发射器手机实时看，反之亦然）。
class CloudSync {
  CloudSync._();
  static bool _ready = false;
  static bool get isReady => _ready;

  /// 编译时内置的项目信息（CI 从 Secrets 经 --dart-define 注入，不进仓库）：
  /// 手机/手表装包即带连接信息，用户只输账号密码（或手表输 6 位配对码），
  /// 再也不用在手表上敲 URL/key。本地没配过时自动用内置值初始化。
  /// 本地手动填的优先（可切换项目/换 key）。
  static const _builtInUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const _builtInAnon =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
  static bool get hasBuiltIn =>
      _builtInUrl.isNotEmpty && _builtInAnon.isNotEmpty;

  static const _kUrl = 'cloud_url';
  static const _kAnon = 'cloud_anon';
  static const _store = FlutterSecureStorage();

  static SupabaseClient get _c => Supabase.instance.client;
  static String? get uid {
    try {
      if (!_ready) return null;
      return _c.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// 注意：App 刚装、还没配过 url+key 时 Supabase 根本没初始化，
  /// 直接读 instance.client 会抛异常白屏——这里吞掉返回未登录。
  static bool get loggedIn {
    try {
      if (!_ready) return false;
      return _c.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  /// 启动时调：本机有存过的 url+key 才初始化（没配过就是纯本机模式，不报错）
  /// 包里带了内置项目信息（CI --dart-define 注入）时自动用它初始化，
  /// 手机/手表装完就能登录，不用敲 URL/key。
  static Future<bool> initFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var url = prefs.getString(_kUrl);
      var anon = await _store.read(key: _kAnon);
      if ((url == null || url.isEmpty || anon == null || anon.isEmpty) &&
          hasBuiltIn) {
        url = _builtInUrl;
        anon = _builtInAnon;
      }
      if (url == null || url.isEmpty || anon == null || anon.isEmpty) {
        return false;
      }
      await Supabase.initialize(url: url, publishableKey: anon);
      
      _ready = true;
      if (prefs.getString(_kUrl) == null && hasBuiltIn) {
        // 内置值首刷：存一份到本机，后面换 key/切项目走手动覆盖
        await prefs.setString(_kUrl, url);
        await _store.write(key: _kAnon, value: anon);
      }
      return true;
    } catch (_) {
      _ready = false;
      return false;
    }
  }

  /// 首次配置：用户在我的页输入 url+anon key，存本机后初始化
  static Future<bool> configure(String url, String anonKey) async {
    try {
      await Supabase.initialize(url: url.trim(), publishableKey: anonKey.trim());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUrl, url.trim());
      await _store.write(key: _kAnon, value: anonKey.trim());
      
      _ready = true;
      return true;
    } catch (_) {
      _ready = false;
      return false;
    }
  }

  static Future<String?> signUp(String email, String password) async {
    try {
      final r = await _c.auth.signUp(email: email, password: password);
      return r.user == null ? '注册失败，请检查邮箱格式' : null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  static Future<String?> signIn(String email, String password) async {
    try {
      final r =
          await _c.auth.signInWithPassword(email: email, password: password);
      // 登录成功马上把 access/refresh token 存本机：换设备/手表扫码后
      // 直接 recoverSession，不用在手表小屏上再输一遍密码。
      try {
        final s = r.session;
        if (s != null) await _saveSessionTokens(s);
      } catch (_) {}
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  static Future<void> signOut() async {
    try {
      await _c.auth.signOut();
    } catch (_) {}
    // token 清掉：否则下一台设备/下一个账号可能复用到旧会话
    try {
      await _store.delete(key: _kAccess);
      await _store.delete(key: _kRefresh);
    } catch (_) {}
  }

  // ---------------- token 存取（换设备/手表免输密码登录用） ----------------

  static const _kAccess = 'cloud_access_token';
  static const _kRefresh = 'cloud_refresh_token';

  static Future<void> _saveSessionTokens(Session s) async {
    try {
      await _store.write(key: _kAccess, value: s.accessToken);
      final rt = s.refreshToken;
      if (rt != null && rt.isNotEmpty) {
        await _store.write(key: _kRefresh, value: rt);
      }
    } catch (_) {}
  }

  /// 本机存过 token（手机登录过）→ 直接恢复会话，不用输密码。
  /// 返回 null 成功，非 null 是失败原因。
  /// access 必须非空（gotrue recoverSession 要求 json 里有 access_token，
  /// 光 refresh 不行——手机登录时两个都存，这里两个都要有）。
  static Future<String?> signInWithSavedTokens() async {
    try {
      final access = await _store.read(key: _kAccess);
      final refresh = await _store.read(key: _kRefresh);
      if (access == null ||
          access.isEmpty ||
          refresh == null ||
          refresh.isEmpty) {
        return '本机没存过登录（先在手机上登录一次，或用扫码把登录传过来）';
      }
      final r = await _c.auth.setSession(refresh);
      final s = r.session;
      if (s != null) await _saveSessionTokens(s);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// 扫码登录：手表扫手机上的二维码（内容就是下面的串），直接恢复同一会话。
  /// payload 格式：access\x00refresh（base64 url-safe 编码过一次）。

  static Future<String?> readLoginQrPayload() async {
    try {
      final access = await _store.read(key: _kAccess);
      final refresh = await _store.read(key: _kRefresh);
      if (access == null ||
          access.isEmpty ||
          refresh == null ||
          refresh.isEmpty) {
        return null;
      }
      final raw = '$access\x00$refresh';
      return base64Url.encode(utf8.encode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 手表扫到上面的串 → 同一账号直接登录，不用输密码。
  /// gotrue setSession(refresh) 只用 refresh 走 /token 刷新拿新 access，
  /// 二维码里拼 access 是为了将来直接恢复、少一次网络（现在先走刷新链路）。
  static Future<String?> signInWithQrPayload(String payload) async {
    try {
      final raw = utf8.decode(base64Url.decode(payload.trim()));
      final i = raw.indexOf('\x00');
      if (i <= 0) return '二维码不对，重新扫一下';
      final access = raw.substring(0, i);
      final refresh = raw.substring(i + 1);
      if (access.isEmpty || refresh.isEmpty) return '二维码不对，重新扫一下';
      final r = await _c.auth.setSession(refresh);
      final s = r.session;
      if (s != null) await _saveSessionTokens(s);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  // ---------------- 配对码登录（手表无摄像头，用 6 位数字代替扫码） ----------------
  //
  // 手机已登录 → createPairingCode() 生成 6 位码（5 分钟有效，一次即焚）；
  // 手表输入 6 位码 → redeemPairingCode() 取回同一会话的 token 直接登录。
  // 需在 Supabase 后台执行 supabase_pairing.sql（表 + 两个函数）一次。

  static String _newPairCode() {
    final r = DateTime.now().microsecondsSinceEpoch % 1000000;
    return r.toString().padLeft(6, '0');
  }

  /// 手机侧：把当前会话 token 存到云端配对码，返回 6 位码（失败返回 null）。
  static Future<String?> createPairingCode() async {
    try {
      if (!_ready || !loggedIn) return null;
      final s = _c.auth.currentSession;
      if (s == null || (s.refreshToken ?? '').isEmpty) return null;
      await _saveSessionTokens(s);
      final code = _newPairCode();
      await _c.rpc('create_pairing_code', params: {
        'p_code': code,
        'p_access': s.accessToken,
        'p_refresh': s.refreshToken ?? '',
      });
      return code;
    } catch (_) {
      return null;
    }
  }

  /// 手表侧：输入 6 位码 → 同一账号直接登录（一次即焚，5 分钟过期）。
  /// 返回 null 成功，非 null 是失败原因。
  static Future<String?> redeemPairingCode(String code) async {
    if (!_ready) return '本机还没填项目 URL+key，先完成第 1 步';
    try {
      final c = code.trim();
      if (c.length != 6) return '配对码是 6 位数字';
      final rows = await _c.rpc('redeem_pairing_code', params: {'p_code': c});
      final list = (rows as List?) ?? const [];
      if (list.isEmpty) return '码不对或已过期，手机上重新生成一个';
      final m = Map<String, dynamic>.from(list.first as Map);
      final access = '${m['access'] ?? ''}';
      final refresh = '${m['refresh'] ?? ''}';
      if (access.isEmpty || refresh.isEmpty) return '码已失效，重新生成一个';
      final r = await _c.auth.setSession(refresh);
      final s = r.session;
      if (s != null) await _saveSessionTokens(s);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  static Future<void> clearConfig() async {
    try {
      await signOut();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUrl);
      await _store.delete(key: _kAnon);
      _ready = false;
      
    } catch (_) {}
  }

  // ---------------- 上传（单条，失败吞掉等整量同步补） ----------------

  static Future<void> pushReading({
    required int localId,
    required double mmolL,
    required int trend,
    required String brand,
    required String source,
    int? seq,
    required String sensorId,
    required DateTime measuredAt,
  }) async {
    if (!_ready || !loggedIn) return;
    try {
      await _c.from('cloud_readings').upsert({
        'id': 'r$localId',
        'user_id': uid,
        'mmol_l': mmolL,
        'mg_dl': (mmolL * 18.0182).round(),
        'trend': trend,
        'brand': brand,
        'source': source,
        'seq': seq,
        'sensor_id': sensorId,
        'measured_at': measuredAt.toIso8601String(),
      });
    } catch (_) {}
  }

  static Future<void> pushVital({
    required int localId,
    required String kind,
    double? value1,
    double? value2,
    required String unit,
    required String source,
    required String device,
    required DateTime measuredAt,
  }) async {
    if (!_ready || !loggedIn) return;
    try {
      await _c.from('cloud_vitals').upsert({
        'id': 'v$localId',
        'user_id': uid,
        'kind': kind,
        'value1': value1,
        'value2': value2,
        'unit': unit,
        'source': source,
        'device': device,
        'measured_at': measuredAt.toIso8601String(),
      });
    } catch (_) {}
  }

  static Future<void> pushTreatment({
    required int localId,
    required String type,
    required String detail,
    double? amount,
    required String unit,
    required String extra,
    required DateTime measuredAt,
  }) async {
    if (!_ready || !loggedIn) return;
    try {
      await _c.from('cloud_treatments').upsert({
        'id': 't$localId',
        'user_id': uid,
        'type': type,
        'detail': detail,
        'amount': amount,
        'unit': unit,
        'extra': extra,
        'measured_at': measuredAt.toIso8601String(),
      });
    } catch (_) {}
  }

  // ---------------- 下拉整量同步（换设备恢复 / 断网补洞） ----------------
  //
  /// 返回 (补入血糖条数, 补入vitals条数, 补入treatments条数)
  static Future<(int, int, int)> syncAll() async {
    if (!_ready || !loggedIn) return (0, 0, 0);
    await AppDatabase.init();
    var gr = 0, vr = 0, tr = 0;
    try {
      final rows = await _c
          .from('cloud_readings')
          .select()
          .order('measured_at', ascending: true)
          .limit(5000);
      for (final m in (rows as List)) {
        final mmol = (m['mmol_l'] as num?)?.toDouble() ?? 0;
        if (mmol <= 0) continue;
        DateTime ts;
        try {
          ts = DateTime.parse('${m['measured_at']}').toLocal();
        } catch (_) {
          continue;
        }
        final ok = await AppDatabase.instance.importReading(
          mmolL: mmol,
          timestamp: ts,
          brand: '${m['brand'] ?? '云端'}',
        );
        if (ok) gr++;
      }
    } catch (_) {}
    try {
      final rows = await _c
          .from('cloud_vitals')
          .select()
          .order('measured_at', ascending: true)
          .limit(5000);
      for (final m in (rows as List)) {
        DateTime ts;
        try {
          ts = DateTime.parse('${m['measured_at']}').toLocal();
        } catch (_) {
          continue;
        }
        try {
          await AppDatabase.instance.insertVital(
            kind: '${m['kind']}',
            value1: (m['value1'] as num?)?.toDouble(),
            value2: (m['value2'] as num?)?.toDouble(),
            unit: '${m['unit'] ?? ''}',
            source: 'health',
            device: '${m['device'] ?? ''}',
            recordedAt: ts,
          );
          vr++;
        } catch (_) {}
      }
    } catch (_) {}
    try {
      final rows = await _c
          .from('cloud_treatments')
          .select()
          .order('measured_at', ascending: true)
          .limit(2000);
      for (final m in (rows as List)) {
        DateTime ts;
        try {
          ts = DateTime.parse('${m['measured_at']}').toLocal();
        } catch (_) {
          continue;
        }
        try {
          await AppDatabase.instance.insertTreatment(
            type: '${m['type']}',
            detail: '${m['detail'] ?? ''}',
            amount: (m['amount'] as num?)?.toDouble(),
            unit: '${m['unit'] ?? ''}',
            extra: '${m['extra'] ?? ''}',
            recordedAt: ts,
          );
          tr++;
        } catch (_) {}
      }
    } catch (_) {}
    return (gr, vr, tr);
  }

  // ---------------- Realtime 互通（手机↔手表秒级同步） ----------------
  //
  /// onGlucose: 收到对方血糖 (mmolL, trend, isoTime)
  /// onVital: 收到对方身体指标 (kind, value1, isoTime)
  /// 订阅前确保 Replication 已加三表（见 supabase_schema.sql 第 5 节），
  /// 没加时订阅连上但收不到 INSERT，不报错——后台 SQL 执行完重进 App 即可。
  static RealtimeChannel? _ch;
  static Future<void> subscribeRealtime({
    void Function(double mmolL, int trend, DateTime ts)? onGlucose,
    void Function(String kind, double? v1, double? v2, String unit, DateTime ts)?
        onVital,
  }) async {
    if (!_ready || !loggedIn) return;
    try {
      await _ch?.unsubscribe();
      final me = uid;
      _ch = _c.channel('device-sync');
      _ch!
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'cloud_readings',
            callback: (payload) async {
              try {
                final m = payload.newRecord;
                if (m['user_id'] == me) {
                  // 自己上传的不回环（本机已有，判重也会吞，但少一次库操作）
                  return;
                }
                final mmol = (m['mmol_l'] as num?)?.toDouble() ?? 0;
                if (mmol <= 0) return;
                final ts = DateTime.parse('${m['measured_at']}').toLocal();
                await AppDatabase.init();
                await AppDatabase.instance.importReading(
                  mmolL: mmol,
                  timestamp: ts,
                  brand: '${m['brand'] ?? '云端'}',
                );
                onGlucose?.call(
                    mmol, (m['trend'] as num?)?.toInt() ?? 0, ts);
              } catch (_) {}
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'cloud_vitals',
            callback: (payload) async {
              try {
                final m = payload.newRecord;
                if (m['user_id'] == me) return;
                final ts = DateTime.parse('${m['measured_at']}').toLocal();
                await AppDatabase.init();
                await AppDatabase.instance.insertVital(
                  kind: '${m['kind']}',
                  value1: (m['value1'] as num?)?.toDouble(),
                  value2: (m['value2'] as num?)?.toDouble(),
                  unit: '${m['unit'] ?? ''}',
                  source: 'health',
                  device: '云同步',
                  recordedAt: ts,
                );
                onVital?.call('${m['kind']}',
                    (m['value1'] as num?)?.toDouble(),
                    (m['value2'] as num?)?.toDouble(),
                    '${m['unit'] ?? ''}', ts);
              } catch (_) {}
            },
          )
          .subscribe();
    } catch (_) {}
  }

  static Future<void> unsubscribeRealtime() async {
    try {
      await _ch?.unsubscribe();
    } catch (_) {}
    _ch = null;
  }
}
