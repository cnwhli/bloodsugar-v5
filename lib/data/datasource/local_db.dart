import 'package:flutter/material.dart';
import 'package:drift/drift.dart';
import 'package:drift_sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/bluetooth/cgm_protocol.dart';

/// 本地数据库（drift SQLite）
class AppDatabase {
  static AppDatabase? _instance;
  late final Connection _conn;

  AppDatabase._();

  static Future<AppDatabase> init() async {
    _instance ??= AppDatabase._();
    final dbPath = await getApplicationDocumentsDirectory();
    _instance!._conn = await databaseFactorySqflite.open(
      '${dbPath.path}/bloodsugar.db',
      options: const OpenDatabaseOptions(
        maxOpenConnections: 1,
        version: 1,
        onCreate: _createTables,
      ),
    );
    return _instance!;
  }

  static AppDatabase get instance {
    if (_instance == null) {
      throw StateError('AppDatabase 未初始化，请先调用 AppDatabase.init()');
    }
    return _instance!;
  }

  static Future<void> _createTables(DatabaseExecutor e, int version) async {
    await e.execute('''
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
    await e.execute('''
      CREATE INDEX idx_glucose_time ON glucose_readings(created_at DESC)
    ''');
  }

  /// 插入读数
  Future<int> insertReading(GlucoseReading reading) async {
    final stmt = await _conn.prepare(
      'INSERT INTO glucose_readings (value_mmol_l, trend, brand, source) VALUES (?, ?, ?, ?)',
    );
    return stmt.execute([
      reading.valueMmolL,
      reading.trend,
      reading.brand.displayName,
      'ble',
    ]);
  }

  /// 最近 N 条
  Future<List<Map<String, dynamic>>> recentReadings({int limit = 100}) async {
    final result = await _conn.customSelect(
      'SELECT * FROM glucose_readings ORDER BY created_at DESC LIMIT ?',
      variables: [Variable(limit)],
    );
    return result.map((r) => r.data).toList();
  }

  /// 周统计
  Future<Map<String, dynamic>> weeklyStats() async {
    final result = await _conn.customSelect('''
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
    final row = result.first.data;
    return {
      'total': row['total'],
      'avg': row['avg'],
      'min': row['min_v'],
      'max': row['max_v'],
      'tir': row['tir']?.toStringAsFixed(1) ?? '--',
    };
  }
}
