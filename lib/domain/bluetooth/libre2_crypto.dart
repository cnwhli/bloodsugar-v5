/// Libre 2 BLE 解密 + 解析（移植自 DiaBLE gui-dos/DiaBLE，GPLv3，见文件头）。
///
/// 链条：NFC 扫一次拿 uid(8B)+patchInfo → BLE FDE3 建连 → F002 收 46B
/// (20+18+8) → decryptBLE 解密 → CRC16 校验 → parseBLEData 取 10 个点。
///
/// 状态：解密/解析函数已就绪；BLE 建连握手 + NFC 取 uid 待真机联调后接线。
library;

// DiaBLE Libre2.swift key/secret（硬编码常量，原样移植）
const List<int> _kKey = [0xA0C5, 0x6860, 0x0000, 0x14C6];
const int _kSecret = 0x1b6a;

int _u16le(int lo, int hi) => (lo & 0xFF) | ((hi & 0xFF) << 8);

/// Dart 侧公用的 LE16（cgm_protocol 等调用方用，包内共享实现）
int libreU16le(int lo, int hi) => _u16le(lo, hi);

List<int> _prepareVariables(List<int> id, int x, int y) {
  final s1 = ((_u16le(id[5], id[4]) + x + y) & 0xFFFF);
  final s2 = ((_u16le(id[3], id[2]) + _kKey[2]) & 0xFFFF);
  final s3 = ((_u16le(id[1], id[0]) + x * 2) & 0xFFFF);
  final s4 = (0x241a ^ _kKey[3]) & 0xFFFF;
  return [s1, s2, s3, s4];
}

int _op(int value) {
  var res = (value >> 2) & 0x3FFF;
  if ((value & 1) != 0) res ^= _kKey[1];
  if ((value & 2) != 0) res ^= _kKey[0];
  return res & 0xFFFF;
}

List<int> _processCrypto(List<int> input) {
  final r0 = (_op(input[0]) ^ input[3]) & 0xFFFF;
  final r1 = (_op(r0) ^ input[2]) & 0xFFFF;
  final r2 = (_op(r1) ^ input[1]) & 0xFFFF;
  final r3 = (_op(r2) ^ input[0]) & 0xFFFF;
  final r4 = _op(r3);
  final r5 = _op(r4 ^ r0);
  final r6 = _op(r5 ^ r1);
  final r7 = _op(r6 ^ r2);
  final f1 = (r0 ^ r4) & 0xFFFF;
  final f2 = (r1 ^ r5) & 0xFFFF;
  final f3 = (r2 ^ r6) & 0xFFFF;
  final f4 = (r3 ^ r7) & 0xFFFF;
  return [f4, f3, f2, f1];
}

/// usefulFunction：4 字节派生（activate/enableStreaming 命令签名用；解密也用）
List<int> _usefulFunction(List<int> id, int x, int y) {
  final blockKey = _processCrypto(_prepareVariables(id, x, y));
  final low = blockKey[0];
  final high = blockKey[1];
  // LibreTools#2：与取反后的 low/high 异或
  final r1 = (low ^ 0x4163) & 0xFFFF;
  final r2 = (high ^ 0x4344) & 0xFFFF;
  return [r1 & 0xFF, (r1 >> 8) & 0xFF, r2 & 0xFF, (r2 >> 8) & 0xFF];
}

/// CRC16（DiaBLE Extensions.swift Data.crc16，原样移植）。
/// 注意：这是 LSB-first 的逐位算法（字节内从 bit0 开始），
/// 与 CRC16-CCITT-FALSE 的 MSB-first 不同——"123456789" 得 0x89F6，
/// 不是标准 FALSE 的 0x29B1。解密校验必须用这个，不能换标准库！
int libreCrc16(List<int> data) {
  var crc = 0xFFFF;
  for (final byte in data) {
    for (var i = 0; i <= 7; i++) {
      final bit = (((crc >> 15) & 1) ^ ((byte >> i) & 1)) & 0xFF;
      crc = ((crc << 1) ^ (bit == 1 ? 0x1021 : 0)) & 0xFFFF;
    }
  }
  return crc;
}

/// 按位读（DiaBLE Libre.swift readBits，原样移植）
int libreReadBits(List<int> buf, int byteOffset, int bitOffset, int bitCount) {
  if (bitCount == 0) return 0;
  var res = 0;
  for (var i = 0; i < bitCount; i++) {
    final total = byteOffset * 8 + bitOffset + i;
    if (total < 0) continue;
    final byte = total ~/ 8;
    final bit = total % 8;
    if (byte < buf.length && (((buf[byte] >> bit) & 1) == 1)) {
      res |= (1 << i);
    }
  }
  return res;
}

/// 解密 Libre 2 BLE 46 字节载荷（DiaBLE Libre2.decryptBLE，原样移植）。
/// id = NFC 扫到的 8 字节 uid；data = F002 收齐的 46 字节。
/// 成功返回 44 字节明文（42 数据 + 2 CRC），失败抛 StateError。
List<int> libre2DecryptBle(List<int> id, List<int> data) {
  final d = _usefulFunction(id, 0x1B /* activate */, _kSecret);
  final x = (((_u16le(d[1], d[0]) ^ _u16le(d[3], d[2])) | 0x63) & 0xFFFF);
  final y = ((_u16le(data[1], data[0]) ^ 0x63) & 0xFFFF);
  var blockKey = _processCrypto(_prepareVariables(id, x, y));
  final key = <int>[];
  for (var k = 0; k < 8; k++) {
    for (final w in blockKey) {
      key.add(w & 0xFF);
      key.add((w >> 8) & 0xFF);
    }
    blockKey = _processCrypto(blockKey);
  }
  final payload = data.sublist(2); // 44 字节
  final result = List<int>.generate(
      payload.length, (i) => (payload[i] ^ key[i]) & 0xFF);
  final body = result.sublist(0, 42);
  final want = _u16le(result[42], result[43]);
  if (libreCrc16(body) != want) {
    throw StateError('BLE data decryption failed');
  }
  return result;
}

/// BLE 解密后的 44 字节明文 → 血糖点（DiaBLE Sensor.parseBLEData，原样移植）。
/// 返回最多 10 个点：7 趋势 + 3 历史；每个 {mgDl, minsAgo}。
/// wearMinutes = data[40..41]（佩戴分钟数）。
List<Map<String, int>> libre2ParseBle(
  List<int> data, {
  required int nowWearMinutes,
}) {
  final wearTimeMinutes = _u16le(data[40], data[41]);
  final startOffset = nowWearMinutes - wearTimeMinutes; // 分钟回拨基数
  const sparse = [0, 2, 4, 6, 7, 12, 15];
  final out = <Map<String, int>>[];
  for (var i = 0; i < 10; i++) {
    final rawValue = libreReadBits(data, i * 4, 0, 0xE);
    if (rawValue == 0) continue; // 错误点跳过
    // DiaBLE Glucose: value = rawValue / 10（mmol/L 小数），mg/dL = raw/10*18
    final mgDl = (rawValue * 1.8).round();
    int minsAgo;
    if (i < 7) {
      minsAgo = startOffset + sparse[i];
    } else {
      // 历史点：15 分钟对齐，每 15 分钟一个
      final lastHist = ((wearTimeMinutes - 2) ~/ 15) * 15;
      minsAgo = startOffset + (wearTimeMinutes - (lastHist - 15 * (i - 7)));
    }
    out.add({'mgDl': mgDl, 'minsAgo': minsAgo});
  }
  return out;
}
