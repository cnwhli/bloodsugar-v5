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
      version: 3,
      onCreate: _createTables,
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS community_posts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              user_name TEXT DEFAULT '糖友',
              content TEXT NOT NULL,
              glucose_mmol_l REAL,
              tag TEXT,
              likes INT DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now','localtime'))
            )
          ''');
        }
        if (oldV < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS pump_devices (
              device_id TEXT PRIMARY KEY,
              brand TEXT,
              device_name TEXT,
              paired_at TEXT DEFAULT (datetime('now','localtime'))
            )
          ''');
        }
      },
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
    await db.execute('''
      CREATE TABLE community_posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_name TEXT DEFAULT '糖友',
        content TEXT NOT NULL,
        glucose_mmol_l REAL,
        tag TEXT,
        likes INT DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now','localtime'))
      )
    ''');
    await db.execute('''
      CREATE TABLE pump_devices (
        device_id TEXT PRIMARY KEY,
        brand TEXT,
        device_name TEXT,
        paired_at TEXT DEFAULT (datetime('now','localtime'))
      )
    ''');
  }

  /// 插入读数（BLE / 广播 / 手动通用）
  Future<int> insertReading(GlucoseReading reading) async {
    return _db!.insert('glucose_readings', {
      'value_mmol_l': reading.valueMmolL,
      'trend': reading.trend,
      'brand': reading.brand.displayName,
      'source': 'ble',
    });
  }

  /// 去重插入：同数值 45 秒内已有一条则跳过，返回 false。
  /// 前台 manager 和后台 isolate 会同时收到同一条广播、先后调插入，
  /// 不去重库里会成双（同一秒两条 5.5 就是这么来的）。
  /// 窗口只取 45 秒：同一广播的双写一定在几秒内到达，而发射器
  /// 下一分钟的新点至少 55 秒后才来——数值不变也要每分钟留一条，
  /// 所以窗口不能放大到分钟级。
  Future<bool> insertReadingDedup(GlucoseReading reading) async {
    try {
      final rows = await _db!.query(
        'glucose_readings',
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final v =
            (rows.first['value_mmol_l'] as num?)?.toDouble() ?? -999;
        final ts =
            DateTime.tryParse('${rows.first['created_at']}');
        if ((v - reading.valueMmolL).abs() < 0.06 &&
            ts != null &&
            (reading.timestamp.difference(ts).inSeconds).abs() < 45) {
          return false;
        }
      }
    } catch (_) {}
    await insertReading(reading);
    return true;
  }

  /// 插入手动读数（指血 / 其他 App 抄录）
  Future<int> insertManual(double mmolL, {String? notes}) async {
    return _db!.insert('glucose_readings', {
      'value_mmol_l': mmolL,
      'trend': 0,
      'brand': '手动输入',
      'source': 'manual',
      'notes': notes,
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

  /// 最近 24 小时（时间正序，供曲线图；只取 24 小时内，旧数据不画）
  Future<List<Map<String, dynamic>>> readingsLast24h(
      {int limit = 288}) async {
    return _db!.query(
      'glucose_readings',
      where: "created_at >= datetime('now','localtime','-24 hours')",
      orderBy: 'created_at ASC',
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

  // ==================== 社区（本地单机版）====================

  Future<int> insertPost({
    required String userName,
    required String content,
    double? glucoseMmolL,
    String? tag,
  }) async {
    return _db!.insert('community_posts', {
      'user_name': userName,
      'content': content,
      'glucose_mmol_l': glucoseMmolL,
      'tag': tag,
    });
  }

  Future<List<Map<String, dynamic>>> recentPosts({int limit = 20}) async {
    return _db!.query(
      'community_posts',
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<void> likePost(int id) async {
    await _db!.rawUpdate(
      'UPDATE community_posts SET likes = likes + 1 WHERE id = ?',
      [id],
    );
  }

  // ==================== 泵配对记录 ====================

  Future<void> savePumpPairing({
    required String brand,
    required String deviceId,
    required String deviceName,
  }) async {
    await _db!.insert(
      'pump_devices',
      {
        'brand': brand,
        'device_id': deviceId,
        'device_name': deviceName,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> pairedPumps() async {
    return _db!.query('pump_devices', orderBy: 'paired_at DESC');
  }

  Future<void> deletePumpPairing(String deviceId) async {
    await _db!.delete(
      'pump_devices',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }
}