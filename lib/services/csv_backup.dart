import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/datasource/local_db.dart';

/// 💾 CSV 导出/导入——免服务器、零费用备份方案。
///
/// 导出：一键分享到微信/邮件/网盘，自留永久备份。
/// 导入：把 CSV 复制到 App 文档目录，点导入即可补数（按时间+值判重）。
class CsvBackup {
  CsvBackup._();

  /// 导出所有血糖记录为 CSV 并弹出系统分享。
  static Future<void> exportAll() async {
    await AppDatabase.init();
    final rows = await AppDatabase.instance.readingsBetween(
      DateTime(2020), DateTime.now().add(const Duration(days: 1)),
    );
    if (rows.isEmpty) return;
    final buf = StringBuffer();
    buf.writeln('time,value_mmol_l,value_mg_dl,trend,brand,source,min_from_start,sensor_id');
    for (final r in rows) {
      final time = (r['created_at'] ?? '').toString().replaceAll(',', ' ');
      final vMmol = (r['value_mmol_l'] as num?)?.toDouble().toStringAsFixed(1) ?? '';
      final vMg = ((r['value_mmol_l'] as num?)?.toDouble() ?? 0) * 18.0182;
      final trend = (r['trend'] as num?)?.toInt() ?? 0;
      final brand = (r['brand'] ?? '').toString().replaceAll(',', ' ');
      final source = (r['source'] ?? '').toString().replaceAll(',', ' ');
      final seq = (r['min_from_start'] as num?)?.toInt() ?? 0;
      final sid = (r['sensor_id'] ?? '').toString().replaceAll(',', ' ');
      buf.writeln('$time,$vMmol,${vMg.toStringAsFixed(0)},$trend,$brand,$source,$seq,$sid');
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/bloodsugar_export.csv');
    await file.writeAsString(buf.toString());
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: '血糖数据备份'),
    );
  }

  /// 从 App 文档目录导入 CSV（bloodsugar_import.csv）。
  ///
  /// 操作步骤：
  ///   1. 把 CSV 文件复制到 /Android/data/com.cnwhli.bloodsugar_v5/files/（或用 ADB push）
  ///   2. 点"我的页→导入 CSV"
  ///
  /// 格式：time,mmol 列即可（至少两列），其余列忽略。走 importReading 判重。
  /// 返回补入条数；-1 = 文件不存在。
  static Future<int> importFromDocDir() async {
    await AppDatabase.init();
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/bloodsugar_import.csv');
    if (!await file.exists()) return -1;
    final lines = await file.readAsLines();
    var added = 0;
    for (final line in lines) {
      if (line.startsWith('time') || line.trim().isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 2) continue;
      final timeStr = parts[0].trim();
      final valStr = parts[1].trim();
      final val = double.tryParse(valStr);
      if (val == null || val <= 0 || val > 30) continue;
      DateTime t;
      try { t = DateTime.parse(timeStr); } catch (_) { t = DateTime.now(); }
      final ok = await AppDatabase.instance.importReading(
        mmolL: val,
        timestamp: t,
        brand: 'CSV导入',
      );
      if (ok) added++;
    }
    return added;
  }
}
