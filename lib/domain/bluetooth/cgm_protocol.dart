/// CGM BLE 协议层（真实协议版本）
///
/// 协议来源（均为 GPLv3 兼容的开源实现，移植时保留出处）：
/// - AiDEX X / LinX（微泰二代）：Juggluco j-kaltes/Juggluco (GPLv3)
///   Common/src/main/cpp/aidexx/glucose.h — 广播包 62 字节，service 0x181F，
///   Nordic 0x0059 manufacturer data 内含血糖（被动扫描即可读数，无需连接）
/// - Libre 2：DiaBLE gui-dos/DiaBLE Abbott.swift — service FDE3，
///   写 F001（BLE login），通知 F002，46 字节（20+18+8），需 NFC UID 解密
/// - Libre 3：DiaBLE Libre3.swift — data service 089810CC-...，
///   one-minute reading 0898177A-...，ECDH+证书认证
/// - Dexcom G5/G6：xDrip NightscoutFoundation/xDrip g5model/BluetoothServices.java —
///   广播 FEBC，data F8083532-...，auth F8083535-...，challenge-response
/// - Dexcom G7/ONE+：DiaBLE Dexcom.swift/DexcomG7.swift — 同上 + jPake F8083538
/// - Sibionics GS1/GS3（含硅基动感）：Juggluco Si3GattCallback.java —
///   service 00005347-...，写 FF32，通知 FF31
/// - Accu-Chek SmartGuide / CareSens Air：Juggluco AccuGattCallback.java —
///   标准 CGM service 0x181F，measurement 2AA7，RACP 2A52
/// - LibreLinkUp 云 API：DiaBLE LibreLink.swift —
///   api-{region}.libreview.io，llu/auth/login → connections?include=latest-reading
///   （中国区：api-cn.myfreestyle.cn）
/// - Dexcom Share 云 API：xDrip sharemodels/DexcomShare.java —
///   General/LoginPublisherAccountByName
///
/// 状态说明：
/// - AiDEX：被动广播解析 ✅ 可直接用（微泰二代默认走这个）
/// - Libre2：需先 NFC 扫一次拿 UID，之后 BLE 自动解密
/// - Libre3 / Dexcom G6/G7：握手骨架已搭，需真机联调补完
/// - Sibionics / Accu：UUID 已对，解析待真机验证
/// - Medtronic：私有协议无公开实现，仅占位

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../data/datasource/local_db.dart';
import 'libre2_crypto.dart';
import 'sibionics_crypto.dart';

// 128-bit 展开：16-bit UUID -> 标准 base UUID
String _u16(String hex) =>
    '0000${hex.toLowerCase()}-0000-1000-8000-00805f9b34fb';

/// CGM 设备类型枚举
enum CgmBrand {
  aidexX('AiDEX G7 / X（微泰二代）', '0000181f-0000-1000-8000-00805f9b34fb'),
  aidexLinX('AiDEX LinX（微泰分体式，需官方App配对后广播）', '0000181f-0000-1000-8000-00805f9b34fb'),
  libre2('Libre 2', '0000fde3-0000-1000-8000-00805f9b34fb'),
  libre3('Libre 3', '089810cc-ef89-11e9-81b4-2a2ae2dbcce4'),
  dexcomG6('Dexcom G6', 'f8083532-849e-531c-c594-30f1f86a4ea5'),
  dexcomG7('Dexcom G7', 'f8083532-849e-531c-c594-30f1f86a4ea5'),
  sibionics('Sibionics 硅基 GS1/GS3', '00005347-0000-1000-8000-00805f9b34fb'),
  sibionicsLite('Sibionics 硅基轻享/动感分体式（发射器复用，握手待验证）',
      '00005347-0000-1000-8000-00805f9b34fb'),
  sinocareICan('三诺爱看 iCan（一体式，3代传感技术，协议闭源，需抓包验证）',
      '0000181f-0000-1000-8000-00805f9b34fb'),
  ottaiM8('欧态 Ottai M8（14天/5分钟，需官方App激活后抓包验证）',
      '0000181f-0000-1000-8000-00805f9b34fb'),
  accuSmartGuide(
      'Accu-Chek SmartGuide', '0000181f-0000-1000-8000-00805f9b34fb'),
  medtronicGuardian4('Medtronic Guardian 4', '0000181f-0000-1000-8000-00805f9b34fb'),
  medtronicSimplera('Medtronic Simplera', '0000181f-0000-1000-8000-00805f9b34fb'),
  unknown('Unknown', '00000000-0000-1000-8000-00805f9b34fb');

  final String displayName;
  final String serviceUuid;
  const CgmBrand(this.displayName, this.serviceUuid);
}

/// 血糖读数
class GlucoseReading {
  final double valueMgDl; // mg/dL
  final double valueMmolL; // mmol/L
  final DateTime timestamp;
  final int trend; // 0=稳定, 1=上升, 2=大幅上升, 3=下降, 4=大幅下降
  final CgmBrand brand;
  final int? quality; // 信号质量（AiDEX 广播带）
  final int? minFromStart; // 发射器启动分钟序号（AiDEX 广播带，去重用）
  final String sensorId; // 发射器身份（AiDEX 广播名后6位配对码，如 22222FJV7J）
  final String? rawBrand; // 数据库里的原始品牌字串（未知品牌回显用）

  GlucoseReading({
    required this.valueMgDl,
    required this.timestamp,
    this.trend = 0,
    required this.brand,
    this.quality,
    this.minFromStart,
    this.sensorId = '',
    this.rawBrand,
  }) : valueMmolL = valueMgDl / 18.0182;

  /// 显示用品牌名：未知品牌回显数据库原字串（如"手动输入"），不显示 Unknown
  String get brandLabel =>
      (brand == CgmBrand.unknown && rawBrand != null && rawBrand!.isNotEmpty)
          ? rawBrand!
          : brand.displayName;

  /// 从数据库行恢复（created_at 为 "YYYY-MM-DD HH:MM:SS" 本地时间）。
  /// v4 起优先读 value_mg_dl 整数列（规范单位）；老库只有 mmol 列时回退换算。
  /// displayName 改名后老数据可能对不上：再按 serviceUuid/核心关键字兜底。
  factory GlucoseReading.fromDb(Map<String, dynamic> m) {
    final raw = '${m['brand'] ?? ''}';
    var brand = CgmBrand.values.firstWhere(
      (b) => b.displayName == raw || b.name == raw,
      orElse: () => CgmBrand.unknown,
    );
    if (brand == CgmBrand.unknown && raw.contains('AiDEX')) {
      brand = CgmBrand.aidexX; // 老库"AiDEX G7 / X（微泰）"改名后兜底
    }
    DateTime ts;
    try {
      ts = DateTime.parse('${m['created_at']}');
    } catch (_) {
      ts = DateTime.now();
    }
    final mg = m['value_mg_dl'] as num?;
    final mgDl = mg != null
        ? mg.toDouble()
        : ((m['value_mmol_l'] as num?)?.toDouble() ?? 0) * 18.0182;
    return GlucoseReading(
      valueMgDl: mgDl,
      timestamp: ts,
      trend: (m['trend'] as num?)?.toInt() ?? 0,
      brand: brand,
      minFromStart: (m['min_from_start'] as num?)?.toInt(),
      sensorId: '${m['sensor_id'] ?? ''}',
      rawBrand: brand == CgmBrand.unknown && raw.isNotEmpty ? raw : null,
    );
  }

  String get status {
    if (valueMgDl < 70) return 'low';
    if (valueMgDl > 180) return 'high';
    return 'normal';
  }
}

/// BLE 连接状态
enum BleCgmState {
  idle,
  scanning,
  connecting,
  connected,
  syncing,
  error,
}

/// CGM 协议基类（默认空实现，子类按需覆盖）
abstract class CgmProtocol {
  CgmBrand get brand;

  /// 广播 service UUID（用于扫描过滤），被动广播型也可复用
  List<String> get serviceUuids => const [];

  /// 需要订阅的 notify characteristic UUID（连接型）
  List<String> get subscriptionUuids => const [];

  /// 是否被动广播型（无需连接，扫描到即解析）
  bool get isAdvertisementBased => false;

  /// 扫描结果匹配判定
  bool matches(ScanResult r) => false;

  /// 连接型：从 notify 数据解析血糖
  Future<GlucoseReading?> parseReading(Uint8List data) async => null;

  /// 广播型：从广播包解析血糖（默认只取当前点；AiDEX 重写取 3 点）
  Future<GlucoseReading?> parseAdvertisement(ScanResult r) async => null;

  /// 广播型多点解析：一个广播包里带的历史点也一起收回来。
  /// 默认实现 = 单点（parseAdvertisement）；AiDEX 重写返回 [当前, 前1分, 前2分]。
  Future<List<GlucoseReading>> parseAdvertisementAll(ScanResult r) async {
    final one = await parseAdvertisement(r);
    return one == null ? const [] : [one];
  }

  /// 连接型：建连 + 握手 + 订阅（默认实现：发现服务→订阅 notify）
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    await device.connect(autoConnect: false);
    await device.discoverServices();
    for (final service in device.servicesList) {
      for (final c in service.characteristics) {
        if (subscriptionUuids.contains(c.uuid.toString().toLowerCase())) {
          await c.setNotifyValue(true);
          log('已订阅 ${c.uuid}');
          c.onValueReceived.listen((data) async {
            final reading =
                await parseReading(Uint8List.fromList(data));
            if (reading != null) onReading(reading);
          });
        }
      }
    }
  }
}

/// 趋势映射（来自 cgmpatches）
const Map<int, int> trendMap = {
  0: 0, // Flat
  1: 1, // FortyFiveUp
  2: 2, // SingleUp
  3: 3, // FortyFiveDown
  4: 4, // SingleDown
  5: 5, // DoubleUp
  6: 6, // DoubleDown
};

// ==================== AiDEX X / LinX（微泰二代）====================
/// 连接方式（对标"与糖"APP + Juggluco aidexx）：
/// 1. 发射器名如 AiDEX x-22222FJV7J，配对码 = 名字最后 6 位（见发射器贴纸）。
/// 2. 先 GATT 连接（ bonding 配对，一次即可，系统记住密钥），
/// 3. 配对成功后发射器才在 0x181F 广播里放明文血糖（62 字节，1 分钟一次）——
///    这就是"配对后免连、听广播就行"的真相：与糖也是这样，配对一次、以后被动收。
/// 4. 所以"扫描"是两步：先扫到名（配对）→ 再持续听广播（收数）。
///    配对信息（MAC + 6位码）存本机，下次自动认，不用再输。
/// Juggluco aidexx/glucose.h：
/// 广播 62 字节：flags + service 0x181F + manufacturer(Nordic 0x0059) +
/// LastPast{minfromstart u16, status u8, calTemp u8, trend i8,
///   glucose:10/warmup:1/unknown:4/valid:1 u16, quality u8} +
/// prev[2] + reserved + crc32 + 完整设备名
/// 例：glucose=119 → 119 mg/dL，trend=-5（×0.1 = -0.5 mg/dL/min）
// ---- AiDEX 广播 CRC 校验（Juggluco aidexx/crc.cpp + glucose.h，原样移植）----
// crc32_normal：多项式 0x04C11DB7，高位先行，初值 = mkseed()。
int _crc32Normal(List<int> buf, int len, int crc) {
  var c = crc & 0xFFFFFFFF;
  var i = 0;
  while (len-- > 0) {
    c ^= (buf[i++] & 0xFF) << 24;
    for (var b = 0; b < 8; b++) {
      if ((c & 0x80000000) != 0) {
        c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF;
      } else {
        c = (c << 1) & 0xFFFFFFFF;
      }
    }
  }
  return c;
}

/// seed = 16 字节载荷内 4 个 LE32 之和 % 0x7FA777（Juggluco glucose.h mkseed）。
int _mkSeed(List<int> mfg) {
  int w(int off) =>
      (mfg[off] & 0xFF) |
      ((mfg[off + 1] & 0xFF) << 8) |
      ((mfg[off + 2] & 0xFF) << 16) |
      ((mfg[off + 3] & 0xFF) << 24);
  return (w(0) + w(4) + w(8) + w(12)) % 0x7FA777;
}

/// 验包：mfg[0..15]（LastPast + prev[2] + reserved）算 CRC，与 mfg[16..19]
/// 的 crc32 字段比对。长度不够 20 字节时（某些系统截断）放行，保兼容。
bool _goodCrc(List<int> mfg) {
  if (mfg.length < 20) return true;
  final calc = _crc32Normal(mfg, 0x10, _mkSeed(mfg));
  final want = (mfg[16] & 0xFF) |
      ((mfg[17] & 0xFF) << 8) |
      ((mfg[18] & 0xFF) << 16) |
      ((mfg[19] & 0xFF) << 24);
  return calc == want;
}

class AidexProtocol extends CgmProtocol {
  @override
  CgmBrand get brand => CgmBrand.aidexX;

  @override
  List<String> get serviceUuids => [_u16('181F')];

  @override
  List<String> get subscriptionUuids => const [];

  @override
  bool get isAdvertisementBased => true;

  @override
  bool matches(ScanResult r) {
    final name = (r.advertisementData.advName).toLowerCase();
    if (name.contains('aidex')) return true;
    // 无名广播：靠 service 181F + Nordic manufacturer 包结构判定
    final mfg = r.advertisementData.manufacturerData;
    if (r.advertisementData.serviceUuids
            .map((g) => g.toString().toLowerCase())
            .contains(_u16('181F')) &&
        mfg.containsKey(0x0059) &&
        (mfg[0x0059]?.length ?? 0) >= 10) {
      return true;
    }
    return false;
  }

  /// 最近一次解析失败的原因（给诊断日志看；成功时清空）。
  /// 之前从"附近"到"入库"之间所有失败都是静默 return []，
  /// 手表看到发射器却没数，完全不知道卡在哪——现在每步都留一句话。
  static String lastDiag = '';

  @override
  Future<List<GlucoseReading>> parseAdvertisementAll(ScanResult r) async {
    final mfg = r.advertisementData.manufacturerData[0x0059];
    if (mfg == null) {
      lastDiag = 'AiDEX诊断：这包只有名字没有厂家数据（分包广播，下一包就有，不用管）';
      return const [];
    }
    if (mfg.length < 15) {
      lastDiag = 'AiDEX诊断：厂家数据过短 len=${mfg.length}（系统截断，把手表靠近发射器试试）';
      return const [];
    }
    // 坏包直接扔：CRC 不对的整包丢弃，不进库不污染曲线
    // （Juggluco glucose.h goodcrc()；系统截断不足 20 字节时放行保兼容）。
    if (!_goodCrc(mfg)) {
      lastDiag = 'AiDEX诊断：CRC校验失败（坏包已丢弃不污染曲线；偶发正常，一直刷就是离得远/有干扰）';
      return const [];
    }
    // 发射器身份 = 广播名后6位配对码（如 AiDEX x-22222FJV7J → 22FJV7J…
    // 取后6位与发射器贴纸/配对码一致）。换发射器后 minFromStart 从 0 重计，
    // 去重必须按（序号, 发射器）联合判，否则旧唯一索引把新发射器的点全吞掉。
    final advName = r.advertisementData.advName;
    final sensorId = advName.length >= 6
        ? advName.substring(advName.length - 6).toUpperCase()
        : advName.toUpperCase();
    // LastPast（当前分钟）: minfromstart(2) status(1) calTemp(1) trend(1)
    // glucose(2) quality(1)，之后紧跟 prev[0]、prev[1]（各 3 字节：
    // glucose:10/unknown:5/valid:1 + quality(1)），分别对应前 1、2 分钟。
    final out = <GlucoseReading>[];
    final now = DateTime.now();
    int o = 0;
    final minFromStart = mfg[o] | (mfg[o + 1] << 8);
    o += 2;
    o += 1; // status
    o += 1; // calTemp
    var trendRaw = mfg[o];
    o += 1;
    if (trendRaw >= 128) trendRaw -= 256; // int8
    final g0 = mfg[o], g1 = mfg[o + 1];
    o += 2;
    final glucose = g0 | ((g1 & 0x03) << 8); // 10-bit mg/dL
    final valid = (g1 >> 7) & 0x01;
    final quality = mfg[o];
    o += 1;
    final rate = trendRaw * 0.1;
    final trend = rate >= 2
        ? 2
        : rate >= 1
            ? 1
            : rate <= -2
                ? 4
                : rate <= -1
                    ? 3
                    : 0;
    if (valid == 1 && glucose >= 18 && glucose <= 800) {
      out.add(GlucoseReading(
        valueMgDl: glucose.toDouble(),
        timestamp: now,
        trend: trend,
        brand: brand,
        quality: quality,
        minFromStart: minFromStart,
        sensorId: sensorId,
      ));
    }
    // prev 两分钟：时间戳按分钟回拨，保证曲线不断点
    for (var i = 0; i < 2; i++) {
      if (o + 3 > mfg.length) break;
      final p0 = mfg[o], p1 = mfg[o + 1];
      final pq = mfg[o + 2];
      o += 3;
      final pg = p0 | ((p1 & 0x03) << 8);
      final pv = (p1 >> 7) & 0x01;
      final pm = minFromStart - (i + 1);
      if (pv == 1 && pg >= 18 && pg <= 800 && pm >= 0) {
        out.add(GlucoseReading(
          valueMgDl: pg.toDouble(),
          timestamp: now.subtract(Duration(minutes: i + 1)),
          trend: 0, // 历史点无趋势字节，画平
          brand: brand,
          quality: pq,
          minFromStart: pm,
          sensorId: sensorId,
        ));
      }
    }
    if (out.isEmpty) {
      lastDiag = 'AiDEX诊断：发射器标 valid=$valid glucose=$glucose（预热/故障时为0，官方App里也无数值可对照）';
    } else {
      lastDiag = '';
    }
    return out;
  }

  @override
  Future<GlucoseReading?> parseAdvertisement(ScanResult r) async {
    final all = await parseAdvertisementAll(r);
    return all.isEmpty ? null : all.first;
  }
}

// ==================== Libre 2 ====================
/// DiaBLE Abbott.swift：service FDE3，写 F001，通知 F002。
/// 46 字节分 3 包（20+18+8），AES 解密需要传感器 UID（先 NFC 扫一次）。
class Libre2Protocol extends CgmProtocol {
  /// NFC 扫到的传感器 UID（解密必需）。App 里扫一次后常驻内存。
  static List<int>? sensorUid;

  /// 佩戴分钟数（F002 明文 data[40..41] 回填，用于历史点时间戳）。
  /// 收不到时默认 0，历史点时间戳按收到时刻算，不挡当前点。
  static int wearMinutes = 0;

  @override
  CgmBrand get brand => CgmBrand.libre2;

  @override
  List<String> get serviceUuids => [_u16('FDE3')];

  @override
  List<String> get subscriptionUuids => [_u16('F002')];

  @override
  bool matches(ScanResult r) {
    return r.advertisementData.serviceUuids
        .map((g) => g.toString().toLowerCase())
        .contains(_u16('FDE3'));
  }

  final List<int> _buffer = [];

  @override
  Future<GlucoseReading?> parseReading(Uint8List data) async {
    // 20 字节开头 → 新一帧
    if (data.length == 20) _buffer.clear();
    _buffer.addAll(data);
    if (_buffer.length < 46) return null; // 等收齐 20+18+8
    if (sensorUid == null) {
      // 无 UID 解不了密，丢掉这一帧等 NFC
      _buffer.clear();
      return null;
    }
    try {
      final plain = libre2DecryptBle(sensorUid!, _buffer.sublist(0, 46));
      final nowWear = libreU16le(plain[40], plain[41]);
      if (nowWear > 0) wearMinutes = nowWear;
      final pts = libre2ParseBle(plain, nowWearMinutes: wearMinutes);
      _buffer.clear();
      if (pts.isEmpty) return null;
      final p0 = pts.first;
      return GlucoseReading(
        valueMgDl: p0['mgDl']!.toDouble(),
        timestamp:
            DateTime.now().subtract(Duration(minutes: p0['minsAgo']!)),
        trend: 0,
        brand: brand,
        minFromStart: wearMinutes - p0['minsAgo']!,
      );
    } catch (_) {
      _buffer.clear(); // CRC 不对：坏包丢掉等下一帧
      return null;
    }
  }
}

// ==================== Libre 3 ====================
/// DiaBLE Libre3.swift：
/// data 089810CC-EF89-11E9-81B4-2A2AE2DBCCE4，
/// one-minute 0898177A-...，patchControl 08981338-...，
/// security 0898203A-...（ECDH + 证书认证流程 CMD_*）。
class Libre3Protocol extends CgmProtocol {
  static const dataSvc = '089810cc-ef89-11e9-81b4-2a2ae2dbcce4';
  static const oneMinute = '0898177a-ef89-11e9-81b4-2a2ae2dbcce4';
  static const patchControl = '08981338-ef89-11e9-81b4-2a2ae2dbcce4';
  static const security = '0898203a-ef89-11e9-81b4-2a2ae2dbcce4';

  @override
  CgmBrand get brand => CgmBrand.libre3;

  @override
  List<String> get serviceUuids => [dataSvc];

  @override
  List<String> get subscriptionUuids => [oneMinute];

  @override
  bool matches(ScanResult r) {
    return r.advertisementData.serviceUuids
        .map((g) => g.toString().toLowerCase())
        .contains(dataSvc);
  }

  @override
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    // TODO: ECDH 证书认证（Libre3.swift CMD_ECDH_START…CMD_ECDH_COMPLETE）
    // 之后订阅 oneMinuteReading，用 decryptPacket(type: .currentGlucose) 解
    log('Libre3 认证流程待真机联调，已发现设备 ${device.platformName}');
    return handleDeviceDefault(device, onReading, log);
  }

  Future<void> handleDeviceDefault(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) =>
      Future.value();
}

// ==================== Dexcom G6 ====================
/// xDrip g5model/BluetoothServices.java：
/// 广播 FEBC；data F8083532-...；communication ...3533；
/// control ...3534；authentication ...3535；backfill ...3536。
/// 认证：AuthRequestTx → challenge → cryptKey "00<serial>00<serial>" AES 解 → response
class DexcomG6Protocol extends CgmProtocol {
  static const advSvc = '0000febc-0000-1000-8000-00805f9b34fb';
  static const dataSvc = 'f8083532-849e-531c-c594-30f1f86a4ea5';
  static const commChr = 'f8083533-849e-531c-c594-30f1f86a4ea5';
  static const ctrlChr = 'f8083534-849e-531c-c594-30f1f86a4ea5';
  static const authChr = 'f8083535-849e-531c-c594-30f1f86a4ea5';

  @override
  CgmBrand get brand => CgmBrand.dexcomG6;

  @override
  List<String> get serviceUuids => [advSvc, dataSvc];

  @override
  List<String> get subscriptionUuids => [commChr, ctrlChr];

  @override
  bool matches(ScanResult r) {
    // G6/G7 只靠广播服务 UUID 匹配：DXCM 开头的名字也可能被其他 Dexcom
    // 外设占用，名字匹配会误抢（手表连不上 AiDEX 的一类嫌疑）。
    final svcs = r.advertisementData.serviceUuids
        .map((g) => g.toString().toLowerCase())
        .toSet();
    return svcs.contains(advSvc) || svcs.contains(dataSvc);
  }

  @override
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    // TODO: AuthRequestTx/AuthChallengeRx 握手（xDrip AuthChallengeTxMessage，
    // key = "00<serial>00<serial>" AES-128），之后订阅 communication 收 glucose
    log('Dexcom G6 握手待真机联调，已发现设备 ${device.platformName}');
  }
}

// ==================== Dexcom G7 / ONE+ ====================
/// DiaBLE Dexcom.swift/DexcomG7.swift：同 G6 services，另 + jPake F8083538
/// 做 J-PAKE 密钥交换；版本号/序列号从 control 读取。
class DexcomG7Protocol extends DexcomG6Protocol {
  static const jpakeChr = 'f8083538-849e-531c-c594-30f1f86a4ea5';

  @override
  CgmBrand get brand => CgmBrand.dexcomG7;

  @override
  List<String> get subscriptionUuids =>
      [DexcomG6Protocol.commChr, DexcomG6Protocol.ctrlChr, jpakeChr];

  @override
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    // TODO: J-PAKE 交换（DexcomG7.swift write(data:for: .jPake)）
    log('Dexcom G7 J-PAKE 待真机联调，已发现设备 ${device.platformName}');
  }
}

// ==================== Sibionics 硅基 GS1/GS3 ====================
/// Juggluco Si3GattCallback.java：
/// service 00005347-...，写 FF32，通知 FF31，MTU 247；
/// 设备名形如 AAC25B18AAFZ（序列号尾 6 位匹配），握手由 gs3Glucose native 驱动。
class SibionicsProtocol extends CgmProtocol {
  static const svc = '00005347-0000-1000-8000-00805f9b34fb';
  static const ff30 = '0000ff30-0000-1000-8000-00805f9b34fb';
  static const notifyChr = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const writeChr = '0000ff32-0000-1000-8000-00805f9b34fb';

  /// GS3 账号 ID（bindUser 用，用户从官方 App 取后填设置；null = 走 GS1 免账号流程）
  static int? accountId;

  @override
  CgmBrand get brand => CgmBrand.sibionics;

  @override
  List<String> get serviceUuids => [svc];

  @override
  List<String> get subscriptionUuids => [notifyChr];

  @override
  bool matches(ScanResult r) {
    final name = r.advertisementData.advName.toUpperCase();
    if (RegExp(r'^[A-Z0-9]{10,}$').hasMatch(name)) return true; // AAC25B18AAFZ 型
    return r.advertisementData.serviceUuids
        .map((g) => g.toString().toLowerCase())
        .contains(svc);
  }

  @override
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    // 硅基是连接型（Juggluco Si3GattCallback 流程）：
    // 连 → MTU 247 → 发现服务 → 订阅 FF31 → 写 26B 认证包 →
    // FF31 notify 经 sibDispatch 分发：glucose 直接出数，ack 按状态机回包。
    // GS3 账号 ID（bindUser 用）：SibionicsProtocol.accountId，未填则
    // 先走 GS1 流程（免账号），收到 Wrong account 再提示用户填。
    try {
      log('连接硅基 ${device.platformName}…');
      await device.connect(autoConnect: false);
      try {
        await device.requestMtu(247);
      } catch (_) {}
      await device.discoverServices();
      // 先把整机服务/特征打出来：GS1 的 FF30/FF31/FF32 不一定全在，
      // 分体款、老固件可能只有 5347 或名字服务。日志里看到底有啥，
      // 再决定走哪条握手——而不是直接报"没找到"。
      final svcList = <String>[];
      for (final s in device.servicesList) {
        final chars = s.characteristics
            .map((c) => c.uuid.toString().substring(4, 8).toUpperCase())
            .join(',');
        svcList.add('${s.uuid.toString().substring(4, 8).toUpperCase()}[$chars]');
      }
      log('硅基服务一览：${svcList.join(' ')}');
      BluetoothCharacteristic? ff31;
      BluetoothCharacteristic? ff32;
      for (final s in device.servicesList) {
        final su = s.uuid.toString().toLowerCase();
        if (su == svc || su == ff30) {
          for (final c in s.characteristics) {
            final cu = c.uuid.toString().toLowerCase();
            if (cu == notifyChr) ff31 = c;
            if (cu == writeChr) ff32 = c;
          }
        }
      }
      // 兜底：不管在哪层 service 下，只要整机有 FF31/FF32 就拿来用
      // （部分固件把 FF31/FF32 挂在 5347 下而非 FF30 下）。
      if (ff31 == null || ff32 == null) {
        for (final s in device.servicesList) {
          for (final c in s.characteristics) {
            final cu = c.uuid.toString().toLowerCase();
            if (cu == notifyChr) ff31 ??= c;
            if (cu == writeChr) ff32 ??= c;
          }
        }
      }
      if (ff31 == null || ff32 == null) {
        log('硅基握手失败：整机无 FF31/FF32（见上行服务一览；'
            '若只有180A/180F说明发射器未激活或被官方App独占，先杀官方App重连）');
        try {
          await device.disconnect();
        } catch (_) {}
        return;
      }
      final w = ff32;
      await ff31.setNotifyValue(true);
      log('已订阅 FF31，写认证包…');
      // 认证包需 RC4 加密后写出
      final mac = device.remoteId.toString();
      final authPlain = sibAuthPacket(mac);
      await w.write(sibRc4(authPlain), withoutResponse: true);
      var lastIndex = 0;
      var bound = false;
      ff31.onValueReceived.listen((data) async {
        final d = sibDispatch(data);
        final action = d['action'];
        if (action == 'glucose') {
          final pts = (d['points'] as List).cast<Map<String, int>>();
          for (final p in pts) {
            if (p['index']! > lastIndex) lastIndex = p['index']!;
            onReading(GlucoseReading(
              valueMgDl: p['mgDl']!.toDouble(),
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                  p['timeSec']! * 1000),
              trend: p['trend']!,
              brand: brand,
              minFromStart: p['index'],
            ));
          }
          // 要下一批：nextid = lastIndex + 1
          try {
            final ask = sibAskDataPacket(lastIndex + 1,
                magic: d['ver'] == 0x10 ? 0x0806 : 0x1406);
            await w.write(sibRc4(ask), withoutResponse: true);
          } catch (_) {}
        } else if (action == 'ack') {
          final raw = (d['raw'] as List).cast<int>();
          // result==2 → Wrong account ID（GS3 账号不对），提示用户填账号
          if (raw.length >= 6 && raw[5] == 2 && !bound) {
            log('硅基 GS3：账号 ID 不对，请在设置里填 GS3 账号 ID 后重连');
            return;
          }
          // 握手推进：先时间同步，再要数据（GS1 免账号流程；GS3 有账号则 bindUser）
          try {
            final acct = SibionicsProtocol.accountId;
            if (acct != null && !bound) {
              bound = true;
              await w.write(
                  sibRc4(sibBindUserPacket(acct, seq: 1)),
                  withoutResponse: true);
            } else {
              await w.write(sibRc4(sibTimeSyncPacket()),
                  withoutResponse: true);
              await Future.delayed(const Duration(milliseconds: 300));
              final ask = sibAskDataPacket(lastIndex + 1, magic: 0x0806);
              await w.write(sibRc4(ask), withoutResponse: true);
            }
          } catch (_) {}
        }
      });
      log('硅基握手已发，等待 FF31 回包…（日志会显示 glucose/ack）');
    } catch (e) {
      log('硅基连接异常：$e');
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }
}

// ==================== Accu-Chek SmartGuide / CareSens Air ====================
/// Juggluco AccuGattCallback.java：标准 CGM service 0x181F，
/// measurement 2AA7 / feature 2AA8 / status 2AA9 /
/// sessionStart 2AAA / sessionRun 2AAB / RACP 2A52。
class AccuSmartGuideProtocol extends CgmProtocol {
  @override
  CgmBrand get brand => CgmBrand.accuSmartGuide;

  @override
  List<String> get serviceUuids => [_u16('181F')];

  @override
  List<String> get subscriptionUuids =>
      [_u16('2AA7'), _u16('2A52'), _u16('2AA9')];

  @override
  bool matches(ScanResult r) {
    final name = r.advertisementData.advName.toLowerCase();
    if (name.contains('accu') ||
        name.contains('smartguide') ||
        name.contains('caresens')) {
      return true;
    }
    return false; // 181F 与 AiDEX 复用，不靠 service 匹配
  }

  @override
  Future<GlucoseReading?> parseReading(Uint8List data) async {
    // 标准 CGM Measurement (2AA7)：flags(1) + glucose(2, mg/dL×100? sfloat)…
    // TODO: 按标准 sfloat 解析 + RACP 取历史（AccuGattCallback 流程）
    if (data.length < 4) return null;
    return null;
  }
}

// ==================== 硅基分体式（轻享/动感分体） ===================
/// 同 5347/FF31/FF32 通道，发射器可复用 18 个月、换探头续用。
/// 分体款握手可能与一体式 GS1 不同：先按同命令试，失败则日志提示，
/// 等真机抓包确认后再分支。
class SibionicsLiteProtocol extends SibionicsProtocol {
  @override
  CgmBrand get brand => CgmBrand.sibionicsLite;

  @override
  bool matches(ScanResult r) {
    // 先走父类匹配（设备名 10 位大写数字字母 / 5347 service），
    // 真机确认分体款广播特征后再收紧，避免和一体式抢设备。
    return super.matches(r);
  }

  @override
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    log('硅基分体式：先按 GS1 握手试连 ${device.platformName}，'
        '失败请反馈蓝牙页日志，待真机抓包分支');
    return super.handleDevice(device, onReading, log);
  }
}

// ==================== 三诺爱看 iCan ===================
/// 2023 年上市，第三代传感技术，一体式。目前无公开 BLE 协议：
/// 无开源实现（xDrip/Juggluco/DiaBLE 均未覆盖），需官方 App 配对后抓包
/// 确认广播 service/广播字段。先注册名字匹配占位，不抢其他品牌设备。
class SinocareICanProtocol extends CgmProtocol {
  @override
  CgmBrand get brand => CgmBrand.sinocareICan;

  @override
  List<String> get serviceUuids => [];

  @override
  List<String> get subscriptionUuids => const [];

  @override
  bool matches(ScanResult r) {
    final name = r.advertisementData.advName.toLowerCase();
    return name.contains('sinocare') ||
        name.contains('ican') ||
        name.contains('三诺') ||
        name.contains('爱看');
  }
}

// ==================== 欧态 Ottai M8 ===================
/// 14 天/每 5 分钟，需"欧态健康"App 贴近扫描激活（60 分钟预热）。
/// 目前无公开 BLE 协议，需官方 App 激活后抓包确认广播字段。
/// 先注册名字匹配占位，不抢其他品牌设备。
class OttaiM8Protocol extends CgmProtocol {
  @override
  CgmBrand get brand => CgmBrand.ottaiM8;

  @override
  List<String> get serviceUuids => [];

  @override
  List<String> get subscriptionUuids => const [];

  @override
  bool matches(ScanResult r) {
    final name = r.advertisementData.advName.toLowerCase();
    return name.contains('ottai') ||
        name.contains('欧态') ||
        name.contains('m8');
  }
}

// ==================== BLE CGM 管理器 ====================
class BleCgmManager {
  static final BleCgmManager _instance = BleCgmManager._internal();
  factory BleCgmManager() => _instance;
  BleCgmManager._internal();

  final List<CgmProtocol> _protocols = [
    AidexProtocol(), // 微泰二代（被动广播，优先）
    Libre2Protocol(),
    Libre3Protocol(),
    DexcomG6Protocol(),
    DexcomG7Protocol(),
    SibionicsLiteProtocol(), // 硅基分体式先试（同通道，日志会标分体式）
    SibionicsProtocol(), // 硅基一体式 GS1/GS3
    SinocareICanProtocol(), // 三诺爱看：名字占位，协议待抓包
    OttaiM8Protocol(), // 欧态 M8：名字占位，协议待抓包
    AccuSmartGuideProtocol(),
    // Medtronic 私有协议无公开实现，暂不注册
  ];

  List<CgmProtocol> get protocols => List.unmodifiable(_protocols);

  final Set<String> _connecting = {};
  BluetoothDevice? _connectedDevice;
  BleCgmState _state = BleCgmState.idle;
  final _stateController = StreamController<BleCgmState>.broadcast();
  final _readingController = StreamController<GlucoseReading>.broadcast();
  final _logController = StreamController<String>.broadcast();

  // 页面切换/切后台不丢数据：读数缓存在 manager（单例）里，页面只订阅显示
  final List<GlucoseReading> _history = [];
  List<GlucoseReading> get history => List.unmodifiable(_history);
  void _emitReading(GlucoseReading r) {
    _history.insert(0, r);
    if (_history.length > 200) _history.removeLast();
    if (!_readingController.isClosed) _readingController.add(r);
  }

  /// 历史补洞通道：广播包里带的 prev 点（前 1/2 分钟）批量入库。
  /// 只补库里没有的序号（按 minFromStart 判重），不进 _history、不发通知、
  /// 不触发报警——避免刚打开 App 时旧点刷屏、报警误报。
  /// 回调 onBackfilled 让页面有机会刷新曲线（节流后调用）。
  void Function(int count)? onBackfilled;

  DateTime _lastBackfillNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _backfillHistory(List<GlucoseReading> olds) async {
    var added = 0;
    for (final r in olds) {
      try {
        final ok =
            await AppDatabase.instance.insertReadingDedup(r);
        if (ok) added++;
      } catch (_) {}
    }
    if (added > 0) {
      final now = DateTime.now();
      // 补洞通知节流 30 秒：广播几秒一次，每次都刷新页面太浪费
      if (now.difference(_lastBackfillNotify).inSeconds >= 30) {
        _lastBackfillNotify = now;
        try {
          onBackfilled?.call(added);
        } catch (_) {}
        _log('补回历史 $added 条');
      }
    }
  }

  bool _managerDisposed = false;

  BleCgmState get state => _state;
  Stream<BleCgmState> get stateStream => _stateController.stream;
  Stream<GlucoseReading> get readingStream => _readingController.stream;
  Stream<String> get logStream => _logController.stream;

  void _log(String s) {
    if (!_logController.isClosed) _logController.add(s);
  }

  void _setState(BleCgmState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  StreamSubscription<List<ScanResult>>? _scanSub;

  /// Android 7+ 系统级限制：BLE 扫描约 30 分钟后会被系统自动停掉
  /// （省电策略），表现为"放着不动就没数了"。看门狗每 25 分钟无感
  /// 续期一次：只调平台 stop/start，不碰 _scanSub 订阅，数据流不断。
  Timer? _scanWatchdog;

  void _startScanWatchdog() {
    _stopScanWatchdog();
    _scanWatchdog =
        Timer.periodic(const Duration(minutes: 25), (_) async {
      if (_state == BleCgmState.scanning) {
        try {
          await FlutterBluePlus.stopScan();
          await FlutterBluePlus.startScan(
            continuousUpdates: true,
            removeIfGone: const Duration(minutes: 2),
            androidScanMode: AndroidScanMode.lowLatency,
          );
          _log('扫描保活：已自动续期（防系统 30 分钟停扫）');
        } catch (e) {
          _log('扫描保活失败：$e');
        }
        return;
      }
      // 掉出 scanning 但前台还要扫（报错/被系统停掉，如截图 40 分钟空洞）：
      // 自动拉起，不等用户动手。后台 isolate 不走这条（它用低功耗轮询）。
      if (foregroundScanActive) {
        _log('监听掉线，自动拉起…');
        await startScan(quiet: true);
      }
    });
  }

  void _stopScanWatchdog() {
    _scanWatchdog?.cancel();
    _scanWatchdog = null;
  }

  // 去重：同一数值 60 秒内只收一次（AiDEX 广播几秒一次，不去重会刷屏）
  // 注意：按“分钟序号(minFromStart)”去重，而不是按数值——
  // 数值长时间不变也必须每分钟收一条，否则曲线成断点、数值"一直不变"
  int? _lastMinFromStart;
  String _lastSensorId = '';
  DateTime _lastEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _shouldEmit(GlucoseReading r) {
    final now = DateTime.now();
    // 同一发射器同一分钟序号 60 秒内只收一次（广播几秒一次，防刷屏）；
    // 换发射器（sensorId 变了）直接放行——序号从 0 重计也要收。
    if (_lastMinFromStart != null &&
        _lastMinFromStart == r.minFromStart &&
        _lastSensorId == r.sensorId &&
        now.difference(_lastEmittedAt).inSeconds < 60) {
      return false;
    }
    _lastMinFromStart = r.minFromStart;
    _lastSensorId = r.sensorId;
    _lastEmittedAt = now;
    return true;
  }

  DateTime _lastDiagAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 链路看门狗：收到任何品牌的新数都喂狗；5 分钟没数 → 提醒断链，
  /// 而不是静默丢数（"手表还是断链"却无感知，就是缺这个）。
  void _linkWatchdog() {
    _lastDataAt = DateTime.now();
    _linkLostBuzzed = false;
  }

  DateTime _lastDataAt = DateTime.now();
  bool _linkLostBuzzed = false;

  /// 供页面/后台定时调用：检查是否断链（5 分钟无新数）
  /// 返回 true = 刚判定断链（调用方负责震动/通知，只触发一次直到恢复）
  bool checkLinkLost() {
    if (!_linkLostBuzzed &&
        DateTime.now().difference(_lastDataAt).inMinutes >= 5) {
      _linkLostBuzzed = true;
      return true;
    }
    return false;
  }

  /// 诊断日志节流：广播一分钟几十包，同类诊断 60 秒只刷一条，免得刷屏
  /// 把真正的数值日志淹没。
  void _diagThrottled(String msg) {
    final now = DateTime.now();
    if (now.difference(_lastDiagAt).inSeconds < 60) return;
    _lastDiagAt = now;
    _log(msg);
  }

  /// 省电轮询（后台/手表用）：扫 15 秒、停 45 秒循环。
  /// 发射器 1 分钟广播一次，15 秒窗口足够抓住；其余时间射频休眠。
  /// 比 continuousScan 省电一个数量级，和发射器 cadence 对齐不漏数。
  Timer? _lowPowerTimer;
  bool _lowPowerRunning = false;
  // 本轮扫描计数：每次 burst 置零，有任何广播进 _attachListener 就 +1。
  // 22 秒后还为 0 = 手表射频真没收到东西（不是解析问题），打一条明确日志，
  // 否则用户只看到"监听中"干等，不知道是没扫到还是扫到没解出来。
  int _burstSeen = 0;
  bool _burstActive = false;

  /// checkPermission=false：给后台 isolate 用——后台弹不出授权框，
  /// request() 会直接返回 denied 导致后台扫不到，必须跳过（前台点扫描时已授过权）。
  /// 这就是"放后台就断、一打开就有"的病根之一。
  Future<String?> startLowPowerWatch({bool checkPermission = true}) async {
    if (checkPermission) {
      final err = await _ensureReady();
      if (err != null) return err;
    }
    await stopLowPowerWatch();
    _lowPowerRunning = true;
    _setState(BleCgmState.scanning);
    _log('省电监听：每分钟扫 15 秒（对齐发射器广播），其余休眠');
    _lowPowerTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _lowPowerBurst());
    _lowPowerBurst(); // 立刻来一次
    return null;
  }

  Future<void> _lowPowerBurst() async {
    if (!_lowPowerRunning) return;
    _attachListener();
    _burstSeen = 0;
    _burstActive = true;
    _log('开始一轮扫描…');
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 20),
        androidScanMode: AndroidScanMode.balanced,
      );
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 22));
    if (!_burstActive) return;
    _burstActive = false;
    if (_burstSeen == 0) {
      _log('本轮扫到 0 个蓝牙设备：手表射频没收到任何广播（远/被手机抢连/手表位置权限受限都可能，先把手机蓝牙关了只留手表再扫一轮）');
    } else {
      _log('本轮扫到 $_burstSeen 个蓝牙设备');
    }
  }

  Future<void> stopLowPowerWatch() async {
    _stopScanWatchdog();
    _lowPowerRunning = false;
    _lowPowerTimer?.cancel();
    _lowPowerTimer = null;
    await _detachListener();
  }

  // ---- 监听 attach/detach（前台持续 / 后台省电共用同一套解析）----

  final Set<String> _seen = {};

  void _attachListener() {
    _scanSub ??= FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        _burstSeen++; // 任何广播都计数：区分"没扫到"和"扫到没解出"
        final id = r.device.remoteId.toString();
        final advName = r.advertisementData.advName;
        if (_seen.add(id)) {
          if (advName.isNotEmpty) {
            _log('附近：$advName（信号 ${r.rssi}dBm，越接近0越近）');
          } else {
            final svcs = r.advertisementData.serviceUuids
                .map((g) => g.toString().substring(4, 8).toUpperCase())
                .join(',');
            _log('附近：(无名) $id 服务[$svcs]（信号 ${r.rssi}dBm）');
          }
        }
        var handled = false;
        for (final protocol in _protocols) {
          if (!protocol.matches(r)) continue;
          handled = true;
          final name = advName.isEmpty ? id : advName;
          if (protocol.isAdvertisementBased) {
            // 多点解析：广播包里带的 prev 历史点也一起收（App 刚开/中间漏扫时补洞）。
            // 同序号去重（_shouldEmit）只放行当前分钟的新点；历史点走批量补洞通道。
            // 关键：当前点的时间戳按发射器分钟序号对齐到整分（minFromStart→整分），
            // 不用 DateTime.now()——否则同分钟的重复广播每次入库时间都不同秒，
            // 按 45 秒回退去重的老逻辑（无序号品牌）误杀，列表出现同秒 4 条。
            protocol.parseAdvertisementAll(r).then((readings) {
              if (readings.isEmpty) {
                // 解出空：把协议里记的原因刷出来（节流），否则"看到设备没数"无从查
                if (protocol is AidexProtocol &&
                    AidexProtocol.lastDiag.isNotEmpty) {
                  _diagThrottled(AidexProtocol.lastDiag);
                }
                return;
              }
              final fresh = readings.first;
              _linkWatchdog(); // 有新数就喂狗：蓝牙链路活着
              if (_shouldEmit(fresh)) {
                _emitReading(fresh);
                _log('${fresh.valueMmolL.toStringAsFixed(1)} mmol/L · '
                    '${fresh.brand.displayName} · 广播');
              }
              if (readings.length > 1) {
                _backfillHistory(readings.sublist(1));
              }
            });
          } else {
            if (_connecting.contains(id)) continue;
            _connecting.add(id);
            _log('发现 $name（${protocol.brand.displayName}），连接中…');
            // 边扫边连必超时（GATT 147）：Android 射频同一时间只能干一件事，
            // 持续扫描占着 radio，connect 直接超时。连之前先停扫，
            // 成败都重开扫描（广播监听不能断）。
            await FlutterBluePlus.stopScan().catchError((_) {});
            _connectToDevice(r.device, protocol).whenComplete(() async {
              _connecting.remove(id);
              try {
                await FlutterBluePlus.startScan(
                  continuousUpdates: true,
                  removeIfGone: const Duration(minutes: 2),
                  androidScanMode: AndroidScanMode.lowLatency,
                );
              } catch (_) {}
            });
          }
          break;
        }
        if (!handled && advName.toLowerCase().contains('aidex')) {
          _diagThrottled(
              'AiDEX诊断：看到名字但包结构对不上（service/厂家数据缺失）——'
              '多是微泰官方App在手机上占着发射器，或手表离得远包被截断');
        }
      }
    });
  }

  Future<void> _detachListener() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await FlutterBluePlus.stopScan().catchError((_) {});
  }

  /// 权限 + 蓝牙就绪检查（startScan 与 startLowPowerWatch 共用）
  /// 返回 null = 就绪；返回字符串 = 失败原因（已写日志）
  Future<String?> _ensureReady() async {
    // 0. 先报环境：安卓版本决定走哪套权限（12+走SCAN/CONNECT，11及以下
    // 靠定位+BLUETOOTH/BLUETOOTH_ADMIN）。日志里一眼看出权限模型对不对。
    var sdk = 0;
    if (Platform.isAndroid) {
      try {
        sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      } catch (_) {}
    }
    _log('环境：Android SDK $sdk');
    // 1. 权限：Android 12+(SDK31+)要 BLUETOOTH_SCAN/CONNECT；
    // Android 11 及以下（OPPO Watch X 就是 SDK30）走定位 + 旧蓝牙权限，
    // SCAN/CONNECT 申请了也白给——必须看定位批没批。
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final location = await Permission.locationWhenInUse.request();
    final locAlways = await Permission.location.status;
    _log('权限：SCAN=${scan.name} CONNECT=${connect.name} 定位=${location.name}(当前${locAlways.name})');
    if (sdk >= 31) {
      if (!scan.isGranted || !connect.isGranted) {
        const msg = '缺少蓝牙权限：请在系统设置 → 应用 → 血糖管家 → 权限中允许"附近的设备"';
        _log(msg);
        _setState(BleCgmState.error);
        return msg;
      }
    } else {
      // SDK30 及以下：定位是 BLE 扫描的命门，不批就直接报错，别往下走
      if (!location.isGranted) {
        const msg = '定位权限被拒：安卓11及以下扫BLE必须开定位（系统设置→应用→血糖管家→权限→位置→允许）';
        _log(msg);
        _setState(BleCgmState.error);
        return msg;
      }
    }
    // 通知权限（前台服务常驻通知用，不强制）
    await Permission.notification.request();

    // 2. 蓝牙开关
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      const msg = '手机蓝牙没开：请打开蓝牙后再点扫描';
      _log(msg);
      _setState(BleCgmState.error);
      return msg;
    }
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {}
    return null;
  }

  /// 开始扫描 CGM 设备（前台持续监听，点"断开"才停）。
  /// 注意：主 isolate 的 startScan 与后台 isolate 的常驻扫描**不能并存**——
  /// flutter_blue_plus 新版 startScan 前会先 _stopScan() 停掉已有扫描
  /// （见 fbp 1.36.8 src/flutter_blue_plus.dart startScan：already scanning → stop existing scan），
  /// 而停止是**进程级**的：主 isolate 点开始监听，会把后台 isolate 的扫描一起停掉，
  /// 后台 onStart 里挂的 _sub 从此收不到广播——"手表一进页面就断、灭屏才有数"的病根。
  /// 所以：后台服务在跑时，前台只挂 _attachListener 收广播，不调平台 startScan
  /// （_attachListener 已用 ??= 防重挂；scanResults 是 isolate 内广播流，不调
  /// startScan 也能收到后台 isolate 触发的平台扫描结果——同一进程共享蓝牙栈）。
  /// 返回 null = 权限/蓝牙就绪；返回字符串 = 失败原因（已同时写日志）
  /// quiet=true：后台切回前台自动续扫时用，不重复刷"开始监听"日志
  /// 前台扫描标记：App 从后台切回前台时，若标记为 true 且系统停了扫，自动续扫
  /// 后台服务运行标记：由 CgmForegroundService.start/stop 置位（经 setBackgroundRunning
  /// 注入，避免 protocol 层 import UI 层）。为 true 时 startScan 只挂监听不碰平台扫描。
  bool foregroundScanActive = false;
  static bool backgroundRunning = false;
  Future<String?> startScan({bool quiet = false}) async {
    final err = await _ensureReady();
    if (err != null) return err;
    await stopLowPowerWatch();

    _setState(BleCgmState.scanning);
    foregroundScanActive = true;
    if (!quiet) {
      _log('开始监听…（AiDEX/微泰二代广播自动收数，无需配对）');
      _log('注意：微泰官方 App 会独占发射器——扫之前先杀掉它');
    }
    if (backgroundRunning) {
      // 后台服务正扫着：只挂监听，不调平台 startScan（调了会把后台的停掉）
      _attachListener();
      if (!quiet) _log('后台服务正在监听，直接复用，不重启扫描');
      _startScanWatchdog(); // 保活：后台被杀时前台能自动拉起
      return null;
    }

    // AiDEX 是被动广播：持续监听，不设 timeout，点"断开"才停。
    // 数值每分钟变一次（minFromStart 递增即新数据）。
    await _detachListener();
    try {
      _attachListener();
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(minutes: 2),
        // 不设 timeout：持续监听，点"断开"才停
        androidScanMode: AndroidScanMode.lowLatency,
      );
      _log('监听已启动：发射器每分钟广播一次，有新数自动入库…');
      _startScanWatchdog(); // 防 Android 30 分钟自动停扫
    } catch (e) {
      final msg = '启动扫描失败：$e';
      _log(msg);
      _setState(BleCgmState.error);
      return msg;
    }

    return null;
  }

  Future<void> _connectToDevice(
      BluetoothDevice device, CgmProtocol protocol) async {
    _setState(BleCgmState.connecting);
    try {
      await protocol.handleDevice(device, (reading) {
        _emitReading(reading); // 进 history 缓存，切页/重进不丢
      }, _log);
      _connectedDevice = device;
      _setState(BleCgmState.connected);
      _log('已连接 ${device.platformName}');
    } catch (e) {
      _log('连接失败：$e');
      _connecting.remove(device.remoteId.toString());
      _setState(BleCgmState.error);
    }
  }

  /// 断开/停止：停省电轮询 + 停扫描 + 断 GATT。切页面不调这个，只有点"断开"和退出才调。
  /// 注意：不断后台服务（前台服务由"断开"按钮经 CgmForegroundService.stop 另行停，
  /// 这里只停前台自己的扫描，避免误杀后台收数）。
  Future<void> disconnect() async {
    foregroundScanActive = false;
    _stopScanWatchdog();
    await stopLowPowerWatch();
    if (!backgroundRunning) {
      await _detachListener();
    }
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _connecting.clear();
    _setState(BleCgmState.idle);
    _log('已停止监听');
  }

  /// 释放资源——注意：页面切换不要调这个！只有 App 彻底退出才调。
  /// BleScannerScreen.dispose 已改为空，manager 随 App 单例常驻，
  /// 后台监听 + 省电轮询靠 stopScan()/startLowPowerWatch() 控制。
  void dispose() {
    if (_managerDisposed) return;
    _managerDisposed = true;
    _stateController.close();
    _readingController.close();
    _logController.close();
    disconnect();
  }
}
