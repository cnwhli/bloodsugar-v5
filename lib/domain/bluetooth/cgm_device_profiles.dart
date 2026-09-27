/// 各家 CGM 设备档案（单源真相，2026-09-27 联网核对）。
///
/// 出处：各家官网/说明书/监管文件——
/// 微泰 microtechmd.com（AiDEX X 一体式 15 天/每分钟；G7 14 天免校准实时）；
/// 硅基 sibionics.com/en.sibionics.com（GS1 14 天效期，60 分钟预热，MARD 8.83%）；
/// 三诺 sinocare.com（iCan i3/I3 15 天/3 分钟出值，H3/h3 8 天；全球首个第三代传感）；
/// 欧态 ottai.com.cn/筑医台（M8 14 天/5 分钟，30 分钟出值，MARD 8.11%）；
/// Abbott（Libre 2 14 天/每分钟检查但扫码取值；Libre 3/3 Plus 14/15 天/每分钟自动）；
/// Dexcom 官网（G6 10 天/5 分钟/2 小时预热；G7 10 天或 15 天新型/5 分钟/30 分钟预热/12 小时宽限）；
/// Accu-Chek 英国官网+说明书 PDF（SmartGuide 14 天/5 分钟/1 小时预热/12 小时后校准/到期前 24h+2h 提醒）；
/// Medtronic FDA SSED P250012B（Guardian 4 7 天分体+发射器；Simplera Sync 6 天+24h 宽限一体免校准）；
/// 鱼跃安耐糖 CT3 欧版说明书（CT3 14 天/3 分钟，480 点/天）。
///
/// cadence 出来后，看门狗/断流预警/到期提醒只查这张表，不许再手写"X 分钟"魔法数
/// （教训：之前 3 分钟一刀切，把硅基每个正常 5 分钟间隔都判成断链还重扫掐 GATT）。
class CgmDeviceProfile {
  /// 出值间隔（分钟）：发射器正常情况下多久出一个数
  final int cadenceMin;

  /// 空洞预警线（秒）= cadence + 1 分钟余量：超了只打日志不震动
  final int gapWarnSecs;

  /// 断链线（分钟）= 漏 2 个点左右：超了才震动+续扫
  final int linkLostMins;

  /// 标称佩戴天数（到期提醒用；宽限期/新型号差异见 notes）
  final int wearDays;

  /// 连接方式：broadcast=只听广播（如微泰），direct=直连 GATT，scan=要扫码/触碰取值
  final String linkMode;

  final String notes;
  const CgmDeviceProfile({
    required this.cadenceMin,
    required this.gapWarnSecs,
    required this.linkLostMins,
    required this.wearDays,
    required this.linkMode,
    required this.notes,
  });
}

/// 按 CgmBrand.name 查表（枚举改名也不怕，key 是 name 不是显示名）。
const Map<String, CgmDeviceProfile> cgmDeviceProfiles = {
  'aidexX': CgmDeviceProfile(
    cadenceMin: 1, gapWarnSecs: 90, linkLostMins: 3, wearDays: 14,
    linkMode: 'broadcast',
    notes: 'G7 14天；X一体式15天/每分钟。广播直听，多端可同时收。到期发射器停播，App变不出数。',
  ),
  'aidexLinX': CgmDeviceProfile(
    cadenceMin: 1, gapWarnSecs: 90, linkLostMins: 3, wearDays: 14,
    linkMode: 'broadcast',
    notes: '分体式：需官方App配对激活后才广播；发射器可复用。',
  ),
  'libre2': CgmDeviceProfile(
    cadenceMin: 1, gapWarnSecs: 90, linkLostMins: 3, wearDays: 14,
    linkMode: 'scan',
    notes: '每分钟自查但取值要扫码/触碰，BLE只做高低报警。未扫码=没数，别误判断链。',
  ),
  'libre3': CgmDeviceProfile(
    cadenceMin: 1, gapWarnSecs: 90, linkLostMins: 3, wearDays: 14,
    linkMode: 'direct',
    notes: '3代14天/3 Plus 15天，每分钟自动推送，无需扫描。',
  ),
  'dexcomG6': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 10,
    linkMode: 'direct',
    notes: '10天/5分钟/2小时预热，发射器3个月。社区有重启法，官方按10天锁。',
  ),
  'dexcomG7': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 10,
    linkMode: 'direct',
    notes: '10天（15天新型18岁+）/5分钟/30分钟预热/12小时宽限一体式。注意区分10天版和15天版。',
  ),
  'sibionics': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 14,
    linkMode: 'direct',
    notes: 'GS1/GS3一体式14天/5分钟/60分钟预热。连上后55秒timeSync保活（<60秒链路超时）。',
  ),
  'sibionicsLite': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 14,
    linkMode: 'direct',
    notes: '轻享/动感分体式：发射器复用，握手待验证，同5分钟线。',
  ),
  'sinocareICan': CgmDeviceProfile(
    cadenceMin: 3, gapWarnSecs: 240, linkLostMins: 8, wearDays: 15,
    linkMode: 'direct',
    notes: 'i3/I3 15天/H3/h3医用版8天，每3分钟出值。协议闭源，需抓包验证后才算真正支持。',
  ),
  'ottaiM8': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 240, linkLostMins: 12, wearDays: 14,
    linkMode: 'direct',
    notes: 'M8一体免组装14天/5分钟/30分钟出值。需官方App激活后抓包验证。',
  ),
  'accuSmartGuide': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 14,
    linkMode: 'direct',
    notes: '14天/5分钟/1小时预热，12小时后需指血校准进Therapy模式；到期前24h+2h官方会提醒。',
  ),
  'medtronicGuardian4': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 7,
    linkMode: 'direct',
    notes: '分体7天+发射器（需充电/贴胶布），闭环下免校准、手动模式每天2次指血。主跟780G泵走。',
  ),
  'medtronicSimplera': CgmDeviceProfile(
    cadenceMin: 5, gapWarnSecs: 360, linkLostMins: 12, wearDays: 6,
    linkMode: 'direct',
    notes: '一体免校准6天+24小时宽限，2小时预热。宽限期内继续出数，别在第6天误报到期。',
  ),
};

/// 默认线（未知品牌/没来过数时）：按最严的 1 分钟线收敛，宁可误报不断连。
const defaultGapWarnSecs = 90;
const defaultLinkLostMins = 3;

/// 看门狗 key 是"品牌显示名 · sensorId"，从 key 反查品牌档案。
/// 匹配顺序：先精确（枚举名小写），再关键字；都对不上回 null=走默认线。
CgmDeviceProfile? cgmProfileOf(String devKey) {
  final b = devKey.toLowerCase();
  for (final e in cgmDeviceProfiles.entries) {
    if (b.contains(e.key.toLowerCase())) return e.value;
  }
  if (b.contains('aidex') || b.contains('微泰') || b.contains('动泰')) {
    return cgmDeviceProfiles['aidexX'];
  }
  if (b.contains('sibionics') ||
      b.contains('硅基') ||
      b.contains('gs1') ||
      b.contains('gs3')) {
    return cgmDeviceProfiles['sibionics'];
  }
  if (b.contains('libre') || b.contains('瞬感')) {
    return b.contains('libre 2') || b.contains('libre2')
        ? cgmDeviceProfiles['libre2']
        : cgmDeviceProfiles['libre3'];
  }
  if (b.contains('dexcom') || b.contains('g6') || b.contains('g7')) {
    return b.contains('g7')
        ? cgmDeviceProfiles['dexcomG7']
        : cgmDeviceProfiles['dexcomG6'];
  }
  if (b.contains('sinocare') || b.contains('爱看') || b.contains('ican')) {
    return cgmDeviceProfiles['sinocareICan'];
  }
  if (b.contains('ottai') || b.contains('欧态')) {
    return cgmDeviceProfiles['ottaiM8'];
  }
  if (b.contains('smartguide') || b.contains('罗氏')) {
    return cgmDeviceProfiles['accuSmartGuide'];
  }
  if (b.contains('simplera')) return cgmDeviceProfiles['medtronicSimplera'];
  if (b.contains('guardian') || b.contains('medtronic') || b.contains('美敦力')) {
    return cgmDeviceProfiles['medtronicGuardian4'];
  }
  return null;
}
