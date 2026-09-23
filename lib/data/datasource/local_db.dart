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
      version: 6,
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
        if (oldV < 4) {
          // v4：主存单位改为 mg/dL 整数（规范单位，读写稳定），
          // 同时加 min_from_start 列供按发射器分钟序号去重。
          // SQLite 不支持 ADD GENERATED 列，普通列即可。
          try {
            await db.execute(
                'ALTER TABLE glucose_readings ADD COLUMN value_mg_dl INTEGER');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE glucose_readings ADD COLUMN min_from_start INTEGER');
          } catch (_) {}
          // 老数据回填 mg/dL（只填一次；已有值跳过）
          try {
            await db.execute(
                'UPDATE glucose_readings SET value_mg_dl = ROUND(value_mmol_l * 18.0182) WHERE value_mg_dl IS NULL');
          } catch (_) {}
          try {
            await db.execute(
                'CREATE INDEX idx_glucose_minseq ON glucose_readings(min_from_start)');
          } catch (_) {}
        }
        if (oldV < 5) {
          // v5：新增 vitals 表（运动健康统一入口，心率/血氧/血压/睡眠/步数/体重/运动）。
          // source=health（系统平台自动同步）/manual（无传感器手动补）/ble（直连设备）。
          await db.execute('''
            CREATE TABLE IF NOT EXISTS vitals (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              value1 REAL,
              value2 REAL,
              unit TEXT,
              source TEXT CHECK(source IN ('health','manual','ble')) DEFAULT 'manual',
              device TEXT,
              recorded_at TEXT DEFAULT (datetime('now','localtime')),
              created_at TEXT DEFAULT (datetime('now','localtime'))
            )
          ''');
          try {
            await db.execute(
                'CREATE INDEX idx_vitals_kind_time ON vitals(kind, recorded_at DESC)');
          } catch (_) {}
        }
        if (oldV < 6) {
          // v6：新增 treatments 表（用药/打针/饮食/运动记录，对标欧态健康App日志）。
          await db.execute('''
            CREATE TABLE IF NOT EXISTS treatments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              type TEXT NOT NULL,
              detail TEXT,
              amount REAL,
              unit TEXT,
              extra TEXT,
              recorded_at TEXT DEFAULT (datetime('now','localtime')),
              created_at TEXT DEFAULT (datetime('now','localtime'))
            )
          ''');
          try {
            await db.execute(
                'CREATE INDEX idx_treatments_time ON treatments(recorded_at DESC)');
          } catch (_) {}
        }
      },
    );
  }

  static Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE glucose_readings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        value_mmol_l REAL NOT NULL,
        value_mg_dl INTEGER,
        min_from_start INTEGER,
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
      CREATE INDEX idx_glucose_minseq ON glucose_readings(min_from_start)
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
    // v5 新装：vitals 与升级路径同结构（见 onUpgrade oldV<5）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vitals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        value1 REAL,
        value2 REAL,
        unit TEXT,
        source TEXT CHECK(source IN ('health','manual','ble')) DEFAULT 'manual',
        device TEXT,
        recorded_at TEXT DEFAULT (datetime('now','localtime')),
        created_at TEXT DEFAULT (datetime('now','localtime'))
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_vitals_kind_time ON vitals(kind, recorded_at DESC)
    ''');
    // v6 新装：treatments 与升级路径同结构（见 onUpgrade oldV<6）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS treatments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        detail TEXT,
        amount REAL,
        unit TEXT,
        extra TEXT,
        recorded_at TEXT DEFAULT (datetime('now','localtime')),
        created_at TEXT DEFAULT (datetime('now','localtime'))
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_treatments_time ON treatments(recorded_at DESC)
    ''');
  }

  /// 插入读数（BLE / 广播 / 手动通用）——库里存 mg/dL（整数精度），
  /// mmol/L 只在显示时换算。血糖规范单位是 mg/dL，浮点存 mmol/L 四舍五入
  /// 会导致 5.5→99→5.49 来回抖；存整数 mg/dL 则读写稳定。
  Future<int> insertReading(GlucoseReading reading) async {
    return _db!.insert('glucose_readings', {
      'value_mg_dl': reading.valueMgDl.round(),
      'value_mmol_l': reading.valueMgDl.round() / 18.0182,
      'min_from_start': reading.minFromStart,
      'trend': reading.trend,
      'brand': reading.brand.displayName,
      'source': 'ble',
    });
  }

  /// 去重插入：同一分钟序号（minFromStart）已有则跳过，返回 false。
  /// AiDEX 每分钟广播一个新序号（55 秒窗口是前台/后台 isolate 双写的
  /// 到达差，不是发射器 cadence）。旧逻辑按 45 秒同值去重：上一分钟的
  /// 点和这一分钟的点时间差经常 < 45 秒 → 新点被误杀，看起来像冻结；
  /// 而同一广播的双写必然同序号 → 按序号去重既防双写又不误杀新点。
  /// 没有序号的读数（手动/其他品牌）回退到 45 秒同值去重。
  Future<bool> insertReadingDedup(GlucoseReading reading) async {
    try {
      if (reading.minFromStart != null) {
        final rows = await _db!.query(
          'glucose_readings',
          where: 'min_from_start = ?',
          whereArgs: [reading.minFromStart],
          limit: 1,
        );
        if (rows.isNotEmpty) return false;
      } else {
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

  /// 范围内读数（起止时间戳，供 AGP 报告；时间正序）
  Future<List<Map<String, dynamic>>> readingsBetween(
      DateTime from, DateTime to) async {
    String fmt(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return _db!.query(
      'glucose_readings',
      where: 'created_at >= ? AND created_at <= ?',
      whereArgs: [fmt(from), fmt(to)],
      orderBy: 'created_at ASC',
      limit: 30000,
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

  // ==================== 运动健康（vitals 表）====================
  //
  // kind：heart_rate（心率bpm）/ resting_hr（静息心率）/ spo2（血氧%）/
  //   bp（血压，value1=收缩 value2=舒张）/ sleep（睡眠分钟）/
  //   steps（步数）/ weight（体重kg）/ workout（运动分钟，device=跑步/游泳/步行…）/
  //   calories（消耗kcal）
  // source：health（系统平台自动同步）/ manual（无传感器手动补）/ ble（直连设备）

  Future<int> insertVital({
    required String kind,
    double? value1,
    double? value2,
    String? unit,
    String source = 'manual',
    String? device,
    DateTime? recordedAt,
  }) async {
    String fmt(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return _db!.insert('vitals', {
      'kind': kind,
      'value1': value1,
      'value2': value2,
      'unit': unit,
      'source': source,
      'device': device,
      if (recordedAt != null) 'recorded_at': fmt(recordedAt),
    });
  }

  /// 某指标最近一条（首页今日卡片用）
  Future<Map<String, dynamic>?> latestVital(String kind) async {
    final rows = await _db!.query(
      'vitals',
      where: 'kind = ?',
      whereArgs: [kind],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 某指标今日最近一条（首页"今日健康"手动兜底用：只取今天的，
  /// 昨天的手动数不冒充今天，避免误导）
  Future<Map<String, dynamic>?> todayVital(String kind) async {
    final rows = await _db!.query(
      'vitals',
      where: "kind = ? AND date(recorded_at) = date('now','localtime')",
      whereArgs: [kind],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 某指标最近 N 天（健康页曲线用）
  Future<List<Map<String, dynamic>>> vitalsLastDays(String kind,
      {int days = 7, int limit = 500}) async {
    return _db!.query(
      'vitals',
      where: 'kind = ? AND recorded_at >= datetime(\'now\',\'localtime\',\'-$days days\')',
      whereArgs: [kind],
      orderBy: 'recorded_at ASC',
      limit: limit,
    );
  }

  // ==================== 用药/打针/饮食/运动记录（treatments 表）====================
  //
  // type：insulin（胰岛素）/ medication（口服药）/ food（饮食）/ exercise（运动）/ note（备注）
  // 记录≠给药：只记"打了什么/吃了什么"，不发任何指令到泵（半闭环安全线）。

  Future<int> insertTreatment({
    required String type,
    String? detail, // 药名/食物名/运动名，如"门冬""二甲双胍""螺蛳粉"
    double? amount, // 剂量/数量，如 6（U）、500（mg）
    String? unit, // 单位：U / mg / 碗 / 分钟
    String? extra, // 注射部位/备注，如"腹部"
    DateTime? recordedAt,
  }) async {
    String fmt(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return _db!.insert('treatments', {
      'type': type,
      'detail': detail,
      'amount': amount,
      'unit': unit,
      'extra': extra,
      if (recordedAt != null) 'recorded_at': fmt(recordedAt),
    });
  }

  /// 最近 N 条治疗记录（首页"今日记录" + 记录页列表用）
  Future<List<Map<String, dynamic>>> recentTreatments(
      {int limit = 50}) async {
    return _db!.query(
      'treatments',
      orderBy: 'recorded_at DESC',
      limit: limit,
    );
  }

  /// 今日治疗记录（首页今日卡片用）
  Future<List<Map<String, dynamic>>> todayTreatments() async {
    return _db!.query(
      'treatments',
      where: "date(recorded_at) = date('now','localtime')",
      orderBy: 'recorded_at DESC',
    );
  }

  Future<void> deleteTreatment(int id) async {
    await _db!.delete('treatments', where: 'id = ?', whereArgs: [id]);
  }
}