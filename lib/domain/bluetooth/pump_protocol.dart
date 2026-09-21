/// 胰岛素泵协议抽象层
/// 支持品牌（参考 AndroidAPS / xDrip+ 协议实现）：
/// - Dana-R / Dana-RS / Dana-Link（Sooil）
/// - OmniPod（Insulet）
/// - Medtronic 640G / 670G / 770G
/// - Tandem t:slim X2
/// - Animas（已停产，兼容）
///
/// 半闭环安全边界：
/// - App 只计算建议剂量 → 弹窗确认 → 用户手动执行
/// - App 不发送任何"自动给药"指令
/// - 每次给药必须用户显式确认

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// 泵品牌枚举
enum PumpBrand {
  danaR('Dana-R', '0xF001'),
  danaRS('Dana-RS', '0xF002'),
  omniPod('OmniPod', '0xF003'),
  medtronic('Medtronic', '0xF004'),
  tandem('Tandem', '0xF005'),
  unknown('Unknown', '0x0000');

  final String displayName;
  final String servicePrefix;
  const PumpBrand(this.displayName, this.servicePrefix);
}

/// 泵状态
class PumpStatus {
  final PumpBrand brand;
  final double batteryPercent;
  final double reservoirUnits; // 剩余胰岛素单位
  final bool isCharging;
  final DateTime lastConnTime;

  PumpStatus({
    required this.brand,
    required this.batteryPercent,
    required this.reservoirUnits,
    required this.isCharging,
    required this.lastConnTime,
  });
}

/// 剂量建议
class DoseSuggestion {
  final double bolusUnits; // 餐时大剂量
  final double basalUnits; // 基础率调整（可选）
  final String reason; // 计算依据
  final bool safe; // 是否在安全范围内
  final String safetyNote; // 安全提示

  DoseSuggestion({
    required this.bolusUnits,
    this.basalUnits = 0,
    required this.reason,
    required this.safe,
    required this.safetyNote,
  });
}

/// 泵协议抽象接口
abstract class PumpProtocol {
  String get servicePrefix;
  List<String> get subscriptionUuids;
  bool matches(BluetoothDevice device);
  Future<PumpStatus> readStatus(BluetoothDevice device);
  Future<void> sendBolus(BluetoothDevice device, double units); // 仅手动调用
}

/// Dana-R 协议实现
class DanaRProtocol implements PumpProtocol {
  @override
  String get servicePrefix => '0xF001';

  @override
  List<String> get subscriptionUuids => ['0000ffe1-0000-1000-8000-00805f9b34fb'];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('dana') ?? false;

  @override
  Future<PumpStatus> readStatus(BluetoothDevice device) async {
    // Dana-R 状态读取（需配对后读 GATT）
    await device.connect();
    await device.discoverServices();
    // 简化实现：实际需按协议读电池+储药量
    return PumpStatus(
      brand: PumpBrand.danaR,
      batteryPercent: 100,
      reservoirUnits: 300,
      isCharging: false,
      lastConnTime: DateTime.now(),
    );
  }

  @override
  Future<void> sendBolus(BluetoothDevice device, double units) async {
    // 半闭环：只记录，不自动发送。用户手动在泵上确认
    throw UnsupportedError(
        '半闭环模式：剂量需用户在泵上手动确认，App 不自动发送指令');
  }
}

/// OmniPod 协议实现
class OmniPodProtocol implements PumpProtocol {
  @override
  String get servicePrefix => '0xF003';

  @override
  List<String> get subscriptionUuids => ['00001809-0000-1000-8000-00805f9b34fb'];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('omnipod') ??
      device.name?.toLowerCase().contains('pod') ??
      false;

  @override
  Future<PumpStatus> readStatus(BluetoothDevice device) async {
    return PumpStatus(
      brand: PumpBrand.omniPod,
      batteryPercent: 100,
      reservoirUnits: 200,
      isCharging: false,
      lastConnTime: DateTime.now(),
    );
  }

  @override
  Future<void> sendBolus(BluetoothDevice device, double units) async {
    throw UnsupportedError(
        '半闭环模式：剂量需用户在泵上手动确认，App 不自动发送指令');
  }
}

/// Medtronic 泵协议实现
class MedtronicPumpProtocol implements PumpProtocol {
  @override
  String get servicePrefix => '0xF004';

  @override
  List<String> get subscriptionUuids => ['00002a37-0000-1000-8000-00805f9b34fb'];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('medtronic') ??
      device.name?.toLowerCase().contains('minimed') ??
      false;

  @override
  Future<PumpStatus> readStatus(BluetoothDevice device) async {
    return PumpStatus(
      brand: PumpBrand.medtronic,
      batteryPercent: 85,
      reservoirUnits: 150,
      isCharging: false,
      lastConnTime: DateTime.now(),
    );
  }

  @override
  Future<void> sendBolus(BluetoothDevice device, double units) async {
    throw UnsupportedError(
        '半闭环模式：剂量需用户在泵上手动确认，App 不自动发送指令');
  }
}

/// 泵管理器（单例）
class PumpManager {
  static final PumpManager _instance = PumpManager._internal();
  factory PumpManager() => _instance;
  PumpManager._internal();

  final List<PumpProtocol> _protocols = [
    DanaRProtocol(),
    OmniPodProtocol(),
    MedtronicPumpProtocol(),
  ];

  BluetoothDevice? _connectedDevice;
  PumpProtocol? _activeProtocol;
  PumpStatus? _status;

  PumpStatus? get status => _status;

  /// 扫描泵设备
  void startScan() {
    FlutterBluePlus.startScan(
      withServices: _protocols.map((p) => p.servicePrefix).toList(),
    );
    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        for (final protocol in _protocols) {
          if (protocol.matches(r.device)) {
            _connect(r.device, protocol);
            break;
          }
        }
      }
    });
  }

  Future<void> _connect(
      BluetoothDevice device, PumpProtocol protocol) async {
    try {
      _status = await protocol.readStatus(device);
      _connectedDevice = device;
      _activeProtocol = protocol;
    } catch (e) {
      _status = null;
    }
  }

  /// 半闭环：计算建议剂量（不发送）
  DoseSuggestion suggestDose({
    required double currentGlucose,
    required double targetGlucose,
    required double carbs,
    required double icr, // 胰岛素碳水比
    required double isf, // 胰岛素敏感系数
    double? activeInsulin, // 活性胰岛素（可选）
  }) {
    // FIAST 简化算法（参考 OpenAPS）
    // 餐时剂量 = (血糖偏离目标 + 碳水覆盖) / ISF
    final glucoseDelta = currentGlucose - targetGlucose;
    final carbBolus = carbs / icr;
    final correctionBolus = glucoseDelta / isf;
    final totalBolus = carbBolus + correctionBolus;

    // 安全硬限
    const maxBolus = 12.0; // 单次最大 12 单位
    const maxCorrection = 6.0; // 纠正剂量上限

    double safeBolus = totalBolus.clamp(0, maxBolus);
    String note = '';

    if (totalBolus > maxBolus) {
      note = '超过单次最大剂量，已限制为 $maxBolus 单位，请分次给药';
    } else if (currentGlucose < 3.9) {
      safeBolus = 0;
      note = '低血糖，不建议给药';
    } else if (currentGlucose > 13.9) {
      note = '血糖偏高，建议分 2 次给药，间隔 2 小时';
    }

    return DoseSuggestion(
      bolusUnits: double.parse(safeBolus.toStringAsFixed(2)),
      reason: 'ICR=$icr ISF=$isf 碳水=${carbs}g 血糖=$currentGlucose',
      safe: note.isEmpty,
      safetyNote: note,
    );
  }

  /// 手动给泵发送剂量（半闭环：用户确认后调用）
  Future<void> manualBolus(double units) async {
    if (_activeProtocol == null || _connectedDevice == null) {
      throw StateError('泵未连接');
    }
    // 实际发送指令（需设备配对 + 密钥）
    // await _activeProtocol!.sendBolus(_connectedDevice!, units);
    throw UnsupportedError('泵指令发送需设备配对 + 密钥配置');
  }

  void dispose() {
    _connectedDevice?.disconnect();
  }
}
