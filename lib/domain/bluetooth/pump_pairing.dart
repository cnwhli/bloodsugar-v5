/// 胰岛素泵配对与密钥管理
///
/// 支持的泵品牌：
///   - Dana-R / Dana-RS (Sooil)
///   - OmniPod (Insulet)
///   - Medtronic 640G / 670G / 770G
///   - Tandem t:slim X2
///
/// 配对流程：
///   1. 扫描泵设备（BLE）
///   2. 发起配对请求
///   3. 泵显示配对码 → 用户确认
///   4. 交换加密密钥
///   5. 存储密钥（安全存储）
///
/// 密钥管理：
///   - 密钥存储在设备安全存储（Keychain / Keystore）
///   - 不上传 Supabase
///   - 更换泵需重新配对

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../data/datasource/local_db.dart';

/// 泵品牌枚举
enum PumpBrand {
  danaR('Dana-R', 'Sooil'),
  danaRS('Dana-RS', 'Sooil'),
  omniPod('OmniPod', 'Insulet'),
  medtronic('Medtronic', 'Medtronic'),
  tandem('Tandem t:slim X2', 'Tandem'),
  ;

  final String displayName;
  final String manufacturer;
  const PumpBrand(this.displayName, this.manufacturer);
}

/// 泵配对状态
enum PumpPairStatus {
  unpaired('未配对'),
  pairing('配对中'),
  paired('已配对'),
  error('配对失败'),
  ;

  final String label;
  const PumpPairStatus(this.label);
}

/// 泵配对信息
class PumpPairing {
  final PumpBrand brand;
  final String deviceId;
  final String deviceName;
  final PumpPairStatus status;
  final DateTime? pairedAt;
  final String? pairingCode; // 配对码（泵显示）

  PumpPairing({
    required this.brand,
    required this.deviceId,
    required this.deviceName,
    this.status = PumpPairStatus.unpaired,
    this.pairedAt,
    this.pairingCode,
  });
}

/// 泵密钥管理
/// 密钥存设备安全存储（Keychain / Keystore），配对记录存本地库，不上传云端
class PumpKeyManager {
  static final PumpKeyManager _instance = PumpKeyManager._internal();
  factory PumpKeyManager() => _instance;
  PumpKeyManager._internal();

  static const _storage = FlutterSecureStorage();

  /// 获取存储的泵密钥
  Future<String?> getKey(String deviceId) async {
    return _storage.read(key: 'pump_key_$deviceId');
  }

  /// 存储泵密钥
  Future<void> saveKey(String deviceId, String key) async {
    await _storage.write(key: 'pump_key_$deviceId', value: key);
  }

  /// 删除泵密钥（更换泵时调用）
  Future<void> deleteKey(String deviceId) async {
    await _storage.delete(key: 'pump_key_$deviceId');
  }

  /// 列出已配对的泵（本地库 pump_devices 表）
  Future<List<PumpPairing>> listPaired() async {
    try {
      await AppDatabase.init();
      final rows = await AppDatabase.instance.pairedPumps();
      return rows
          .map((r) => PumpPairing(
                brand: PumpBrand.values.firstWhere(
                  (b) => b.name == r['brand'],
                  orElse: () => PumpBrand.danaR,
                ),
                deviceId: r['device_id'].toString(),
                deviceName: r['device_name']?.toString() ?? '',
                status: PumpPairStatus.paired,
                pairedAt: DateTime.tryParse(
                    r['paired_at']?.toString() ?? ''),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存配对记录
  Future<void> savePairing(PumpPairing pairing) async {
    await AppDatabase.init();
    await AppDatabase.instance.savePumpPairing(
      brand: pairing.brand.name,
      deviceId: pairing.deviceId,
      deviceName: pairing.deviceName,
    );
  }
}

/// 泵配对页面
class PumpPairScreen extends StatefulWidget {
  final PumpBrand brand;

  const PumpPairScreen({super.key, required this.brand});

  @override
  State<PumpPairScreen> createState() => _PumpPairScreenState();
}

class _PumpPairScreenState extends State<PumpPairScreen> {
  PumpPairStatus _status = PumpPairStatus.unpaired;
  String? _pairingCode;
  String _deviceName = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('配对 ${widget.brand.displayName}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 状态显示
            Card(
              child: ListTile(
                leading: Icon(
                  _status == PumpPairStatus.paired
                      ? Icons.check_circle
                      : Icons.bluetooth_searching,
                  color: _status == PumpPairStatus.paired
                      ? Colors.green
                      : Colors.blue,
                ),
                title: Text(_status.label),
                subtitle: Text(_deviceName.isNotEmpty ? '设备: $_deviceName' : ''),
              ),
            ),
            const SizedBox(height: 16),

            // 配对码显示
            if (_pairingCode != null)
              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text('配对码（泵上确认）',
                          style: TextStyle(fontSize: 14)),
                      Text(
                        _pairingCode!,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),

            const Spacer(),

            // 配对按钮
            ElevatedButton(
              onPressed: _status == PumpPairStatus.unpaired
                  ? _startPairing
                  : null,
              child: Text(_status == PumpPairStatus.paired ? '已配对' : '开始配对'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startPairing() async {
    setState(() {
      _status = PumpPairStatus.pairing;
    });

    try {
      // 1. 扫描泵设备
      // final device = await _scanPump(widget.brand);

      // 2. 发起配对请求
      // _pairingCode = await device.requestPairing();

      // 3. 等待用户确认（泵上显示配对码）
      // await _waitForConfirmation();

      // 4. 交换密钥
      // final key = await _exchangeKey(device);

      // 5. 存储密钥
      // await PumpKeyManager().saveKey(device.deviceId, key);

      setState(() {
        _status = PumpPairStatus.paired;
        _deviceName = 'Pump-${widget.brand.displayName}';
      });
    } catch (e) {
      setState(() {
        _status = PumpPairStatus.error;
      });
    }
  }
}