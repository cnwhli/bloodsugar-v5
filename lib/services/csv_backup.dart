import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/datasource/local_db.dart';

/// 无服务器备份：CSV 导出/导入。
///
/// 定位：换手机带走数据、家人共享、官方 App 历史补录，全走这一个文件，
/// 不搭服务器、不注册账号。时间格式与库内一致（YYYY-MM-DD HH:MM:SS 本地）。
class CsvBackup {
  /// 导出全部读数 → 调系统分享（微信发给自己/存文件）。返回导出条数。
  static Future<int> exportAll() async {
    await AppDatabase.init();
    final rows = await AppDatabase.instance.recentReadings(limit: 100000);
    final asc = rows.reversed.toList(); // 库里是 DESC，导出按时间正序
    final sb = StringBuffer('time,mmol,mgdl,trend,brand,source\n');
    for (final m in asc) {
      sb.writeln("${m['created_at']},${m['value_mmol_l']},"
          "${m['value_mg_dl'] ?? ''},${m['trend'] ?? 0},"
          "${m['brand'] ?? ''},${m['source'] ?? ''}");
    }
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/bloodsugar-backup.csv');
    await f.writeAsString(sb.toString());
    await Share.shareXFiles([XFile(f.path)], text: '血糖数据备份（共 ${asc.length} 条）');
    return asc.length;
  }

  /// 导入 CSV（本 App 导出的 / 官方 App 导出的整理成 time,mmol 列即可）。
  /// 返回补入条数；-1 = 用户取消选择。
  static Future<int> importFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    final path = picked?.files.single.path;
    if (path == null) return -1;
    await AppDatabase.init();
    final lines = await File(path).readAsLines();
    var added = 0;
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('time')) continue; // 跳表头
      final cols = t.split(',');
      if (cols.length < 2) continue;
      final ts = DateTime.tryParse(cols[0].trim());
      final mmol = double.tryParse(cols[1].trim());
      if (ts == null || mmol == null) continue;
      final brand = cols.length >= 5 && cols[4].trim().isNotEmpty
          ? cols[4].trim()
          : '导入';
      if (await AppDatabase.instance
          .importReading(mmolL: mmol, timestamp: ts, brand: brand)) {
        added++;
      }
    }
    return added;
  }
}
