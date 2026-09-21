/// Medtronic Guardian 4 / Simplera CGM 协议占位
///
/// Medtronic 私有协议无公开开源实现（xDrip/AndroidAPS 均无直连支持，
/// 只能走 CareLink 云）。此类保留占位，不注册进扫描列表。
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'cgm_protocol.dart';

class MedtronicCgmProtocol extends CgmProtocol {
  MedtronicCgmProtocol();

  @override
  CgmBrand get brand => CgmBrand.medtronicGuardian4;

  @override
  bool matches(ScanResult r) {
    final name = r.advertisementData.advName.toLowerCase();
    return name.contains('medtronic') || name.contains('guardian');
  }

  @override
  Future<void> handleDevice(
    BluetoothDevice device,
    void Function(GlucoseReading) onReading,
    void Function(String) log,
  ) async {
    log('Medtronic 暂无公开 BLE 协议，请走 CareLink 云同步');
  }
}
