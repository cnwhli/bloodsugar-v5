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
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// 128-bit 展开：16-bit UUID -> 标准 base UUID
String _u16(String hex) =>
    '0000${hex.toLowerCase()}-0000-1000-8000-00805f9b34fb';

/// CGM 设备类型枚举
enum CgmBrand {
  aidexX('AiDEX G7 / X（微泰）', '0000181f-0000-1000-8000-00805f9b34fb'),
  libre2('Libre 2', '0000fde3-0000-1000-8000-00805f9b34fb'),
  libre3('Libre 3', '089810cc-ef89-11e9-81b4-2a2ae2dbcce4'),
  dexcomG6('Dexcom G6', 'f8083532-849e-531c-c594-30f1f86a4ea5'),
  dexcomG7('Dexcom G7', 'f8083532-849e-531c-c594-30f1f86a4ea5'),
  sibionics('Sibionics 硅基 GS1/GS3', '00005347-0000-1000-8000-00805f9b34fb'),
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

  GlucoseReading({
    required this.valueMgDl,
    required this.timestamp,
    this.trend = 0,
    required this.brand,
    this.quality,
  }) : valueMmolL = valueMgDl / 18.0182;

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

  /// 广播型：从广播包解析血糖
  Future<GlucoseReading?> parseAdvertisement(ScanResult r) async => null;

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
/// Juggluco aidexx/glucose.h：
/// 广播 62 字节：flags + service 0x181F + manufacturer(Nordic 0x0059) +
/// LastPast{minfromstart u16, status u8, calTemp u8, trend i8,
///   glucose:10/warmup:1/unknown:4/valid:1 u16, quality u8} +
/// prev[2] + reserved + crc32 + 完整设备名
/// 例：glucose=119 → 119 mg/dL，trend=-5（×0.1 = -0.5 mg/dL/min）
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

  @override
  Future<GlucoseReading?> parseAdvertisement(ScanResult r) async {
    final mfg = r.advertisementData.manufacturerData[0x0059];
    if (mfg == null || mfg.length < 10) return null;
    // mfg payload：company(2) 已被 FlutterBluePlus 剥离为 key，
    // 剩余：minfromstart(2) status(1) calTemp(1) trend(1) glucose(2) quality(1) ...
    int o = 0;
    o += 2; // minFromStart：发射器启动分钟数，仅去重参考
    // final status = mfg[o]; o += 1;
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
    if (valid != 1) return null;
    if (glucose < 18 || glucose > 800) return null; // aidexXlowest/highest
    // trend: rate = trend × 0.1 mg/dL/min → 映射 App 趋势
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
    // minFromStart 是发射器启动分钟数，仅用于去重参考
    return GlucoseReading(
      valueMgDl: glucose.toDouble(),
      timestamp: DateTime.now(),
      trend: trend,
      brand: brand,
      quality: quality,
    );
  }
}

// ==================== Libre 2 ====================
/// DiaBLE Abbott.swift：service FDE3，写 F001，通知 F002。
/// 46 字节分 3 包（20+18+8），AES 解密需要传感器 UID（先 NFC 扫一次）。
class Libre2Protocol extends CgmProtocol {
  /// NFC 扫到的传感器 UID（解密必需）。App 里扫一次后常驻内存。
  static List<int>? sensorUid;

  @override
  CgmBrand get brand => CgmBrand.libre2;

  @override
  List<String> get serviceUuids => [_u16('FDE3')];

  @override
  List<String> get subscriptionUuids => [_u16('F002')];

  @override
  bool matches(ScanResult r) {
    final name = r.advertisementData.advName.toLowerCase();
    if (name.contains('libre')) return true;
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
    // TODO: Libre2.decryptBLE(uid, 46B) + CRC16 校验 + parseBLEData
    // 移植目标：DiaBLE Libre2.swift decryptBLE / Crypto.swift
    _buffer.clear();
    return null;
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
    final name = r.advertisementData.advName.toLowerCase();
    if (name.contains('libre')) return true;
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
    final name = r.advertisementData.advName.toLowerCase();
    if (name.startsWith('dxcm') || name.contains('dexcom')) return true;
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
  static const notifyChr = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const writeChr = '0000ff32-0000-1000-8000-00805f9b34fb';

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
    // TODO: FF32 握手命令序列（Si3GattCallback + gs3Glucose），FF31 通知解析
    log('Sibionics 握手待真机联调，已发现设备 ${device.platformName}');
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
    SibionicsProtocol(),
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

  BleCgmState get state => _state;
  Stream<BleCgmState> get stateStream => _stateController.stream;
  Stream<GlucoseReading> get readingStream => _readingController.stream;
  Stream<String> get logStream => _logController.stream;

  void _log(String s) => _logController.add(s);
  void _setState(BleCgmState s) {
    _state = s;
    _stateController.add(s);
  }

  /// 开始扫描 CGM 设备
  Future<void> startScan() async {
    _setState(BleCgmState.scanning);
    _log('开始扫描…（AiDEX/微泰二代靠近手机即自动读数）');

    final services = _protocols
        .expand((p) => p.serviceUuids)
        .toSet()
        .map((u) => Guid(u))
        .toList();
    await FlutterBluePlus.startScan(
      withServices: services,
      timeout: const Duration(seconds: 30),
    );

    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        for (final protocol in _protocols) {
          if (!protocol.matches(r)) continue;
          final name = r.advertisementData.advName.isEmpty
              ? r.device.remoteId.toString()
              : r.advertisementData.advName;
          if (protocol.isAdvertisementBased) {
            // 被动广播：直接解析
            protocol.parseAdvertisement(r).then((reading) {
              if (reading != null) {
                _readingController.add(reading);
                _log('${reading.valueMmolL.toStringAsFixed(1)} mmol/L · '
                    '${reading.brand.displayName} · 广播');
              }
            });
          } else {
            if (_connecting.contains(r.device.remoteId.toString())) continue;
            _connecting.add(r.device.remoteId.toString());
            _log('发现 $name（${protocol.brand.displayName}），连接中…');
            _connectToDevice(r.device, protocol);
          }
          break;
        }
      }
    });

    Future.delayed(const Duration(seconds: 31), () {
      if (_state == BleCgmState.scanning) _setState(BleCgmState.idle);
    });
  }

  Future<void> _connectToDevice(
      BluetoothDevice device, CgmProtocol protocol) async {
    _setState(BleCgmState.connecting);
    try {
      await protocol.handleDevice(device, (reading) {
        _readingController.add(reading);
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

  /// 断开连接
  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _connecting.clear();
    _setState(BleCgmState.idle);
  }

  /// 释放资源
  void dispose() {
    _stateController.close();
    _readingController.close();
    _logController.close();
    disconnect();
  }
}
