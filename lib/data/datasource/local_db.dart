import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../../domain/bluetooth/cgm_protocol.dart';

/// 本地数据库（sqflite）
class AppDatabase {
  static AppDatabase? _instance;
  static Database? _db;

  AppDatabase._();

  static Future<AppDatabase> init() async {
    _instance ??= AppDatabase._();
    await _instance!._open();
    return _instance!;
  }

  static AppDatabase get instance => _instance!;

  Future<void> _open() async {
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'bloodsugar.db'),
      version: 1,
      onCreate: _createTables,
    );
  }

  static Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE glucose_readings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        value_mmol_l REAL NOT NULL,
        value_mg_dl REAL GENERATED ALWAYS AS (ROUND(value_mmol_l * 18.0182, 1)) STORED,
        trend INT DEFAULT 0,
        brand TEXT,
        source TEXT CHECK(source IN ('ble','manual','csv')),
        notes TEXT,
        created_at TEXT DEFAULT (datetime('now','localtime'))
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_glucose_time ON glucose_readings(created_at DESC)
    ''');
  }

  /// 插入读数
  Future<int> insertReading(GlucoseReading reading) async {
    return _db!.insert('glucose_readings', {
      'value_mmol_l': reading.valueMmolL,
      'trend': reading.trend,
      'brand': reading.brand.displayName,
      'source': 'ble',
    });
  }

  /// 最近 N 条
  Future<List<Map<String, dynamic>>> recentReadings({int limit = 100}) async {
    return _db!.query(
      'glucose_readings',
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// 周统计
  Future<Map<String, dynamic>> weeklyStats() async {
    final result = await _db!.rawQuery('''
      SELECT
        COUNT(*) as total,
        AVG(value_mmol_l) as avg,
        MIN(value_mmol_l) as min_v,
        MAX(value_mmol_l) as max_v,
        SUM(CASE WHEN value_mmol_l >= 3.9 AND value_mmol_l <= 10.0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) as tir
      FROM glucose_readings
      WHERE created_at >= datetime('now', '-7 days')
    ''');
    if (result.isEmpty) return {};
    final row = result.first;
    return {
      'total': row['total'],
      'avg': row['avg'],
      'min': row['min_v'],
      'max': row['max_v'],
      'tir': (row['tir'] as double?)?.toStringAsFixed(1) ?? '--',
    };
  }
}