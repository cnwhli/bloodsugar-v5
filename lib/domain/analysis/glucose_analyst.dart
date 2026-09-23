/// 异常波动归因（纯 Dart，可单测）
///
/// 口径：
/// - 高（当前 ≥10.0 且较近期低点上升 ≥2.0）：报饮食升糖，给出行为建议。
///   原因很直白：CGM 只看到血糖曲线，看不到嘴——餐后 2 小时内快速拉升，
///   最大概率就是碳水吃多了。后续接了饮食打卡/胰岛素记录后，再按时间叠加精确归因。
/// - 低（当前 <3.9）：夜间（22点–6点）报夜间低血糖，提示 15-15 原则；
///   白天提示排查运动/胰岛素叠加。
/// - 只做科普归因，不做诊断；调药一律提示咨询医生。

class GlucosePoint {
  final double mmolL;
  final DateTime time;
  const GlucosePoint(this.mmolL, this.time);
}

class HighAnalysis {
  final double peak;
  final String cause;
  final List<String> advice;
  const HighAnalysis({required this.peak, required this.cause, required this.advice});
}

class LowAnalysis {
  final double valley;
  final bool isNight;
  final List<String> advice;
  const LowAnalysis({required this.valley, required this.isNight, required this.advice});
}

const double _highLine = 10.0;
const double _lowLine = 3.9;

/// 高血糖归因：当前点超线 + 近期明显爬升才报，避免平稳高原误报。
HighAnalysis? analyzeHigh(List<GlucosePoint> pts, {required int nowIdx}) {
  if (pts.length < 2 || nowIdx < 0 || nowIdx >= pts.length) return null;
  final cur = pts[nowIdx].mmolL;
  if (cur < _highLine) return null;
  var low = cur;
  final from = (nowIdx - 6).clamp(0, nowIdx);
  for (var i = from; i < nowIdx; i++) {
    if (pts[i].mmolL < low) low = pts[i].mmolL;
  }
  if (cur - low < 2.0) return null; // 一直高但没爬升： basal/黎明等问题，不硬判饮食
  return HighAnalysis(
    peak: cur,
    cause: '饮食升糖：近期从 ${low.toStringAsFixed(1)} 升到 ${cur.toStringAsFixed(1)} mmol/L，'
        '升幅 ${(cur - low).toStringAsFixed(1)}，多半是这顿碳水偏多或高GI食物。',
    advice: const [
      '下一餐先吃菜和蛋白，主食减半、换杂粮/低GI。',
      '餐后 30 分钟散步 15–20 分钟，帮助压平峰值。',
      '用"吃了一碗XX"在 AI 助手里打卡，预测这顿的升糖曲线。',
      '连续几天餐后都超 10.0，带报告去问医生是否调方案。',
    ],
  );
}

/// 低血糖归因：当前点破线即报（安全优先），区分夜间/白天给不同建议。
LowAnalysis? analyzeLow(List<GlucosePoint> pts, {required int nowIdx}) {
  if (pts.length < 2 || nowIdx < 0 || nowIdx >= pts.length) return null;
  final cur = pts[nowIdx].mmolL;
  if (cur >= _lowLine) return null;
  final h = pts[nowIdx].time.hour;
  final night = h >= 22 || h < 6;
  return LowAnalysis(
    valley: cur,
    isNight: night,
    advice: night
        ? const [
            '立即按 15-15 原则：吃 15g 快速碳水（葡萄糖片/果汁），15 分钟后复测。',
            '夜间低血糖重点查：晚餐胰岛素是否偏多、睡前是否漏加餐、白天运动量是否异常大。',
            '设凌晨 3 点闹钟连测几天，做血糖谱给医生看（警惕苏木杰/黎明现象误判）。',
          ]
        : const [
            '立即按 15-15 原则：吃 15g 快速碳水，15 分钟后复测，意识不清不要喂食、立即就医。',
            '排查：餐前胰岛素是否打多、是否空腹运动、两餐间隔是否太长。',
            '随身带糖；开车/高空作业前务必先测。',
          ],
  );
}
