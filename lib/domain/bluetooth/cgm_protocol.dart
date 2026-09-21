/// CGM BLE 抽象层
/// 支持多品牌动态血糖仪直连：
/// - FreeStyle Libre 2 / 3 (Abbott)
/// - Dexcom G6 / G7
/// - Medtronic Guardian 4 / Simplera
/// - 扩展协议可在此添加

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// CGM 设备类型枚举
enum CgmBrand {
  libre2('Libre 2', '0x1234'),
  libre3('Libre 3', '0x1235'),
  dexcomG6('Dexcom G6', '0x2001'),
  dexcomG7('Dexcom G7', '0x2002'),
  medtronicGuardian4('Medtronic Guardian 4', '0x3001'),
  medtronicSimplera('Medtronic Simplera', '0x3002'),
  unknown('Unknown', '0x0000');

  final String displayName;
  final String serviceUuidPrefix;
  const CgmBrand(this.displayName, this.serviceUuidPrefix);
}

/// 血糖读数
class GlucoseReading {
  final double valueMgDl; // mg/dL
  final double valueMmolL; // mmol/L
  final DateTime timestamp;
  final int trend; // 0=稳定, 1=上升, 2=大幅上升, 3=下降, 4=大幅下降
  final CgmBrand brand;

  GlucoseReading({
    required this.valueMgDl,
    required this.timestamp,
    this.trend = 0,
    required this.brand,
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

/// CGM 协议抽象接口
abstract class CgmProtocol {
  /// 该协议支持的 UUID 前缀
  String get servicePrefix;

  /// 从 BLE 特征值解析血糖数据
  Future<GlucoseReading> parseReading(Uint8List data);

  /// 获取需要订阅的 UUID 列表
  List<String> get subscriptionUuids;

  /// 设备匹配判定
  bool matches(BluetoothDevice device);
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

/// Libre 2 协议实现
class Libre2Protocol implements CgmProtocol {
  @override
  String get servicePrefix => '0x1234';

  @override
  List<String> get subscriptionUuids => [
        '00002a18-0000-1000-8000-00805f9b34fb', // Battery
        '0000ffe1-0000-1000-8000-00805f9b34fb', // Libre Data
      ];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('libre') ?? false;

  @override
  Future<GlucoseReading> parseReading(Uint8List data) async {
    // Libre 2 解析：偏移 9 开始 2 字节血糖值 (mg/dL)
    final raw = (data[9] << 8) | data[10];
    final mgDl = raw * 0.05; // 每单位 0.05 mg/dL
    final trendByte = data[12] & 0x0F;
    final Map<int, String> trendNames = {
    0: 'Flat',
    1: 'FortyFiveUp',
    2: 'SingleUp',
    3: 'FortyFiveDown',
    4: 'SingleDown',
    // 5: 'DoubleUp',
    // 6: 'DoubleDown',
  };
    return GlucoseReading(
      valueMgDl: mgDl,
      timestamp: DateTime.now(),
      trend: trendMap[trendByte] ?? 0,
      brand: CgmBrand.libre2,
    );
  }
}

/// Libre 3 协议实现
class Libre3Protocol implements CgmProtocol {
  @override
  String get servicePrefix => '0x1235';

  @override
  List<String> get subscriptionUuids => [
        '00001530-1212-efde-1523-785feabcd123',
      ];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('libre') ?? false;

  @override
  Future<GlucoseReading> parseReading(Uint8List data) async {
    // Libre 3 解析：偏移 1 字节标志 + 2 字节血糖
    final raw = (data[1] << 8) | data[2];
    final mgDl = raw * 0.028; // Libre 3 分辨率
    return GlucoseReading(
      valueMgDl: mgDl,
      timestamp: DateTime.now(),
      brand: CgmBrand.libre3,
    );
  }
}

/// Dexcom G6/G7 协议实现
class DexcomProtocol implements CgmProtocol {
  @override
  String get servicePrefix => '0x2001';

  @override
  List<String> get subscriptionUuids => [
        '00002a37-0000-1000-8000-00805f9b34fb', // Dexcom Data
      ];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('dexcom') ?? false;

  @override
  Future<GlucoseReading> parseReading(Uint8List data) async {
    // Dexcom 解析：偏移 4-5 字节血糖值
    final raw = (data[4] << 8) | data[5];
    final mgDl = raw * 0.028; // Dexcom 分辨率
    return GlucoseReading(
      valueMgDl: mgDl,
      timestamp: DateTime.now(),
      brand: CgmBrand.dexcomG6,
    );
  }
}

/// BLE CGM 管理器（单例）
class BleCgmManager {
  static final BleCgmManager _instance = BleCgmManager._internal();
  factory BleCgmManager() => _instance;
  BleCgmManager._internal();

  final List<CgmProtocol> _protocols = [
    Libre2Protocol(),
    Libre3Protocol(),
    DexcomProtocol(),
    // MedtronicProtocol(), // 后续添加
  ];

  BluetoothDevice? _connectedDevice;
  BleCgmState _state = BleCgmState.idle;
  final _stateController = StreamController<BleCgmState>.broadcast();
  final _readingController = StreamController<GlucoseReading>.broadcast();

  BleCgmState get state => _state;
  Stream<BleCgmState> get stateStream => _stateController.stream;
  Stream<GlucoseReading> get readingStream => _readingController.stream;

  /// 开始扫描 CGM 设备
  void startScan() {
    _state = BleCgmState.scanning;
    _stateController.add(_state);

    FlutterBluePlus.startScan(
      withServices: _protocols.map((p) => Guid(p.servicePrefix)).toList(),
    );

    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        for (final protocol in _protocols) {
          if (protocol.matches(r.device)) {
            _connectToDevice(r.device, protocol);
            break;
          }
        }
      }
    });

    // 30 秒自动停止扫描
    Future.delayed(const Duration(seconds: 30), () {
      if (_state == BleCgmState.scanning) {
        FlutterBluePlus.stopScan();
        if (_state != BleCgmState.connected) {
          _state = BleCgmState.idle;
          _stateController.add(_state);
        }
      }
    });
  }

  Future<void> _connectToDevice(
      BluetoothDevice device, CgmProtocol protocol) async {
    _state = BleCgmState.connecting;
    _stateController.add(_state);

    try {
      await device.connect();
      await device.discoverServices();

      for (final service in device.servicesList) {
        for (final characteristic in service.characteristics) {
          if (protocol.subscriptionUuids
              .contains(characteristic.uuid.toString())) {
            await characteristic.setNotifyValue(true);
            characteristic.value.listen((data) async {
              final reading = await protocol.parseReading(Uint8List.fromList(data));
              _readingController.add(reading);
            });
          }
        }
      }

      _connectedDevice = device;
      _state = BleCgmState.connected;
      _stateController.add(_state);
    } catch (e) {
      _state = BleCgmState.error;
      _stateController.add(_state);
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _state = BleCgmState.idle;
    _stateController.add(_state);
  }

  /// 释放资源
  void dispose() {
    _stateController.close();
    _readingController.close();
    disconnect();
  }
}
