/// 硅基 Sibionics GS1/GS3 BLE 直连（逆向自 Juggluco GPLv3，见文件头出处）。
///
/// 通道：service FF30，notify FF31，write FF32，MTU 247，无系统配对。
/// 加密：标准 RC4，key = 01380B9A005B025DCD9EC3990937AAE8，skip=0；
/// 每包末字节校验和（全包和 ≡ 0）。明文例外：04 00 00 00 FC 不解密。
///
/// GS1：26B 认证包（19 01 00 + MAC反转6B + AppKey + chk）→ 时间同步 →
/// 激活 → 要数据（0x0806）→ 0x08 包出血糖（current/10）。
/// GS3：同认证 → bindUser#1/#2（payload = 账号ID byteswap u64）→
/// deviceInfo → AskNewData（0x1406 + start/end）→ 0x14 包出血糖。
/// GS3 账号 ID 需用户从官方 App 取（或云端换取），不对报 Wrong account ID。
library;

// RC4 key（Juggluco interpret_data.cpp:47，GS1/GS3 共用）
const List<int> _rc4Key = [
  0x01, 0x38, 0x0B, 0x9A, 0x00, 0x5B, 0x02, 0x5D,
  0xCD, 0x9E, 0xC3, 0x99, 0x09, 0x37, 0xAA, 0xE8,
];

// 三个硬编码 App key（按 siSubtype 选）
const String sibAppKeySijoy = 'THE544U0TYITE461'; // sijoy / GS3 应用
const String sibAppKeyRu = 'LQSS54U0RURUA99J'; // 俄版
const String sibAppKeyEco = 'GKSHGDU0TYA456G4'; // sisensingcgm/eco

/// 标准 RC4（skip=0，加解密同函数）
List<int> sibRc4(List<int> data) {
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + _rc4Key[i % _rc4Key.length]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  var i = 0;
  j = 0;
  return List<int>.generate(data.length, (k) {
    i = (i + 1) & 0xFF;
    j = (j + s[i]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
    return (data[k] ^ s[(s[i] + s[j]) & 0xFF]) & 0xFF;
  });
}

/// 和为零校验：全包字节和 ≡ 0 mod 256
bool sibChecksumOk(List<int> pack) {
  var sum = 0;
  for (final b in pack) {
    sum = (sum + b) & 0xFF;
  }
  return sum == 0;
}

/// 补校验字节：chk = (-前面和) & 0xFF
int sibChk(List<int> head) {
  var sum = 0;
  for (final b in head) {
    sum = (sum + b) & 0xFF;
  }
  return (-sum) & 0xFF;
}

/// 组 26 字节认证包明文：19 01 00 + MAC反转6B + AppKey(16B ascii) + chk
/// mac: 本机蓝牙 MAC（AA:BB:CC:DD:EE:FF），deviceArray = 字节反转。
List<int> sibAuthPacket(String mac, {String appKey = sibAppKeySijoy}) {
  final parts = mac.split(':');
  final reversed =
      parts.reversed.map((h) => int.parse(h, radix: 16)).toList();
  final head = [0x19, 0x01, 0x00, ...reversed, ...appKey.codeUnits];
  return [...head, sibChk(head)];
}

/// 组 7 字节时间同步包：06 03 + uint32 LE unix秒 + chk
List<int> sibTimeSyncPacket({int? unixSec}) {
  final t = unixSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final head = [0x06, 0x03, t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF,
    (t >> 24) & 0xFF];
  return [...head, sibChk(head)];
}

/// 组 7 字节要数据包：magic(2B LE) + start u16 + end u16 + chk。
/// GS1 magic=0x0806，GS3 AskNewData magic=0x1406。
/// start = nextid（本地最后 index+1），end = 0。
List<int> sibAskDataPacket(int start, {int magic = 0x1406}) {
  final head = [
    magic & 0xFF, (magic >> 8) & 0xFF,
    start & 0xFF, (start >> 8) & 0xFF, 0x00, 0x00,
  ];
  return [...head, sibChk(head)];
}

/// 组 16 字节 bindUser 包（GS3）：0F 13 seq + 12B payload + chk。
/// payload = 账号ID byteswap 后 u64（大端在前）+ 4 字节 0。
List<int> sibBindUserPacket(int accountId, {int seq = 1}) {
  final idBytes = List<int>.generate(
      8, (i) => (accountId >> (8 * (7 - i))) & 0xFF);
  final head = [0x0F, 0x13, seq, ...idBytes, 0, 0, 0, 0];
  return [...head, sibChk(head)];
}

/// 组 4 字节 deviceInfo 包（GS3）：F0 03 num + (0x0D-num)。
List<int> sibDeviceInfoPacket(int num) => [0xF0, 0x03, num & 0xFF, (0x0D - num) & 0xFF];

int _u16(List<int> b, int o) => (b[o] & 0xFF) | ((b[o + 1] & 0xFF) << 8);
int _u32(List<int> b, int o) =>
    (b[o] & 0xFF) |
    ((b[o + 1] & 0xFF) << 8) |
    ((b[o + 2] & 0xFF) << 16) |
    ((b[o + 3] & 0xFF) << 24);

/// GS3 0x14 包解析（RC4 解密后，明文）。
/// 返回点列 {index, timeSec, mgDl, trend}；trend: 0平/1缓升/2快升/3缓降/4快降。
/// 只留 index % 5 == 0（每 5 分钟一点，与 Juggluco 一致）。
List<Map<String, int>> sibParseGs3(List<int> plain) {
  final out = <Map<String, int>>[];
  if (plain.length < 12 || plain[1] != 0x14) return out;
  if (!sibChecksumOk(plain)) return out;
  final count = plain[2];
  final startIndex = _u16(plain, 3);
  final startTime = _u32(plain, 5);
  var o = 9;
  for (var i = 0; i < count; i++) {
    if (o + 8 > plain.length - 3) break; // 留尾部 reindex(2) + chk(1)
    final bf = plain[o + 6];
    final b10 = plain[o + 7];
    final mmolLx10 = ((b10 << 2) | (bf >> 6)) & 0x3FF;
    final trend = (bf >> 3) & 7;
    final index = startIndex + i;
    if (index % 5 == 0 && mmolLx10 > 0) {
      out.add({
        'index': index,
        'timeSec': startTime + i * 60,
        'mgDl': (mmolLx10 * 1.8).round(),
        'trend': trend > 4 ? 0 : trend,
      });
    }
    o += 8;
  }
  return out;
}

/// GS1 0x08 包解析（RC4 解密后，明文）。
/// header 6B：index u16 + itime u32；每记录 8B：temp/dump/current/extra；
/// 血糖 = current / 10（mg/dL，经校准语义）；尾 2B reindex。
List<Map<String, int>> sibParseGs1(List<int> plain) {
  final out = <Map<String, int>>[];
  if (plain.length < 10 || plain[1] != 0x08) return out;
  if (!sibChecksumOk(plain)) return out;
  final index = _u16(plain, 2);
  final itime = _u32(plain, 4);
  var o = 8;
  var k = 0;
  while (o + 8 <= plain.length - 3) {
    final current = _u16(plain, o + 4);
    final mgDl = (current / 10).round();
    if (mgDl >= 18 && mgDl <= 800) {
      out.add({
        'index': index + k,
        'timeSec': itime + k * 60,
        'mgDl': mgDl,
        'trend': 0,
      });
    }
    o += 8;
    k++;
  }
  return out;
}

/// FF31 notify 分发：解密 → 按 cmd 返回动作。
/// 返回 {'action': 'reply'|'glucose'|'wrongAccount'|'ignore', 'cmd': [...], 'points': [...]}
Map<String, dynamic> sibDispatch(List<int> notify) {
  // 明文 bootstrap 例外
  if (notify.length == 5 &&
      notify[0] == 0x04 &&
      notify[1] == 0x00 &&
      notify[2] == 0x00 &&
      notify[3] == 0x00 &&
      notify[4] == 0xFC) {
    return {'action': 'ignore'};
  }
  final plain = sibRc4(notify);
  if (plain.length < 2 || !sibChecksumOk(plain)) {
    return {'action': 'ignore'};
  }
  final cmd = plain[1];
  if (cmd == 0x14) {
    return {'action': 'glucose', 'points': sibParseGs3(plain), 'ver': 0x15};
  }
  if (cmd == 0x08) {
    return {'action': 'glucose', 'points': sibParseGs1(plain), 'ver': 0x10};
  }
  // ACK 包：buf[0]==4 长度语义，buf[4] 校验和 → 上层按 reply_ack_type 状态机回包
  // （bindUser/deviceInfo/AskNewData/SItime，见 cgm_protocol 接线注释）。
  // result==2 = Wrong account ID（GS3 账号不对）。
  if (plain[0] == 0x04 && plain.length >= 6) {
    return {'action': 'ack', 'raw': plain};
  }
  return {'action': 'ignore'};
}
