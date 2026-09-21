/// Medtronic Guardian 4 / Simplera CGM 协议实现
///
/// 基于参考项目 AndroidAPS / xDrip 的 Medtronic 协议
///
/// 数据包结构：
///   - 0x01 + 0x02 + 0x03: 同步头
///   - Command byte: 读取血糖 / 绑定状态 / 电池
///   - Payload: 血糖值 + 趋势 + 时间戳
///   - CRC8 校验
///
/// 趋势映射（来自 cgmpatches）：
///   0: Flat (→)
///   1: FortyFiveUp (↗)
///   2: SingleUp (↗↑)
///   3: FortyFiveDown (↘)
///   4: SingleDown (↘↓)
///   5: DoubleUp (↗↗)
///   6: DoubleDown (↘↘)

import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'cgm_protocol.dart';

/// Medtronic Guardian 4 / Simplera 协议实现
class MedtronicCgmProtocol extends CgmProtocol {
  MedtronicCgmProtocol();

  @override
  String get servicePrefix => '0x3001';

  @override
  List<String> get subscriptionUuids => [
        '00002a18-0000-1000-8000-00805f9b34fb', // Battery
        '0000ffe1-0000-1000-8000-00805f9b34fb', // Medtronic Data
      ];

  @override
  bool matches(BluetoothDevice device) =>
      device.name?.toLowerCase().contains('medtronic') ?? false;

  @override
  Future<GlucoseReading> parseReading(Uint8List data) async {
    // Medtronic 解析：偏移 4-5 字节血糖值 (mg/dL)
    final raw = (data[4] << 8) | data[5];
    final mgDl = raw * 0.05; // 每单位 0.05 mg/dL
    final trendByte = data[6] & 0x0F;
    return GlucoseReading(
      valueMgDl: mgDl,
      timestamp: DateTime.now(),
      trend: trendMap[trendByte] ?? 0,
      brand: CgmBrand.medtronicGuardian4,
    );
  }

  @override
  bool get isEncrypted => true; // Medtronic 使用 AES-128 加密

  @override
  Future<bool> connect(String deviceId) async {
    // 1. 扫描 Medtronic 设备
    // 2. 配对请求（需要用户确认）
    // 3. 交换配对密钥（物理设备显示）
    // 4. 启动数据订阅
    throw UnimplementedError('Medtronic 连接待配对密钥');
  }

  @override
  Future<GlucoseReading> read() async {
    throw UnimplementedError('read 需配对后使用');
  }

  @override
  Stream<GlucoseReading> subscribe() {
    throw UnimplementedError('subscribe 需配对后使用');
  }

  /// 电池状态
  Future<int> getBatteryLevel() async {
    throw UnimplementedError('battery 需配对后使用');
  }
}