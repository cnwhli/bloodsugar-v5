import 'package:flutter/material.dart';
import '../../domain/bluetooth/cgm_protocol.dart';

/// Supabase Realtime 多端同步服务
///
/// 数据流：
///   手机 App → Supabase Realtime → 手表端 / 社区 / 家属端
///
/// 所有设备通过 user_id 订阅自己的血糖变化
/// 家属通过 family_links 表查看亲属数据

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  /// 手机端：写入新血糖读数
  Future<void> publishReading(GlucoseReading reading) async {
    // Supabase 插入
    // await Supabase.instance.client
    //     .from('glucose_readings')
    //     .insert({
    //       'user_id': userId,
    //       'value_mmol_l': reading.valueMmolL,
    //       'trend': reading.trend,
    //       'brand': reading.brand.displayName,
    //       'source': 'ble',
    //     });
    throw UnimplementedError('publishReading 需配置 Supabase');
  }

  /// 手表端 / 家属端：订阅实时血糖变化
  void subscribe(String userId, void Function(GlucoseReading) onUpdate) {
    // Supabase Realtime 订阅
    // Supabase.instance.client
    //     .channel('glucose:$userId')
    //     .onPostgresChanges(
    //       event: 'INSERT',
    //       schema: 'public',
    //       table: 'glucose_readings',
    //       callback: (payload) {
    //         final reading = GlucoseReading.fromJson(payload['new']);
    //         onUpdate(reading);
    //       },
    //     )
    //     .subscribe();
    throw UnimplementedError('subscribe 需配置 Supabase');
  }

  /// 家属端：获取亲属血糖列表
  Future<List<Map<String, dynamic>>> getFamilyReadings(
      String ownerId) async {
    // 通过 family_links 表找到 member_id
    // 再查 glucose_readings
    throw UnimplementedError('getFamilyReadings 需配置 Supabase');
  }
}

/// 家属远程查看页面
class FamilyWatchScreen extends StatelessWidget {
  final String ownerId;

  const FamilyWatchScreen({super.key, required this.ownerId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('家属远程查看')),
      body: const Center(
        child: Text('家属功能待 Supabase 配置'),
      ),
    );
  }
}
