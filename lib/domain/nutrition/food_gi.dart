/// 食物GI库 + 升糖预测（纯 Dart，可单测）
///
/// 口径：
/// - GI：葡萄糖=100；<55 低，55–70 中，>70 高。数据为常用值，供趋势参考，不做诊疗依据。
/// - 升糖预测公式：rise(mmol/L) ≈ carbsG × GI/100 × k，k=0.055
///   （经验系数：60g碳水×GI60 → 约2.0 mmol/L，与常见餐后升幅量级一致）。
///   有个人历史均值时按 50% 向个人均值靠拢（越用越"懂你"）。

class FoodInfo {
  final String name;
  final int gi; // 升糖指数
  final double carbsPerServingG; // 每份碳水（克）
  final String serving; // 一份的量
  const FoodInfo(this.name, this.gi, this.carbsPerServingG, this.serving);

  String get giLevel => gi < 55 ? '低GI' : gi <= 70 ? '中GI' : '高GI';
}

/// 常见食物库（40+ 种，南方/北方/外卖高频）
const List<FoodInfo> foodTable = [
  FoodInfo('螺蛳粉', 60, 65, '一碗约350g'),
  FoodInfo('桂林米粉', 65, 60, '一碗'),
  FoodInfo('白米饭', 83, 55, '一小碗150g'),
  FoodInfo('白粥', 88, 30, '一碗250g'),
  FoodInfo('馒头', 85, 50, '一个100g'),
  FoodInfo('包子', 70, 35, '一个肉包100g'),
  FoodInfo('面条', 62, 55, '一碗挂面80g干重'),
  FoodInfo('方便面', 70, 55, '一包'),
  FoodInfo('饺子', 60, 40, '10个'),
  FoodInfo('油条', 75, 30, '一根'),
  FoodInfo('烧饼', 72, 45, '一个'),
  FoodInfo('粽子', 65, 50, '一个150g'),
  FoodInfo('炒饭', 75, 60, '一盘'),
  FoodInfo('炒粉', 70, 60, '一盘'),
  FoodInfo('肠粉', 65, 30, '一份'),
  FoodInfo('河粉', 68, 55, '一碗'),
  FoodInfo('米线', 63, 55, '一碗'),
  FoodInfo('红薯', 54, 28, '一个200g'),
  FoodInfo('玉米', 55, 30, '一根'),
  FoodInfo('燕麦', 55, 40, '一碗40g干重'),
  FoodInfo('杂粮饭', 55, 50, '一小碗'),
  FoodInfo('全麦面包', 60, 25, '两片'),
  FoodInfo('白面包', 75, 30, '两片'),
  FoodInfo('蛋糕', 70, 45, '一块100g'),
  FoodInfo('饼干', 70, 35, '5块'),
  FoodInfo('奶茶', 60, 50, '一杯500ml半糖'),
  FoodInfo('可乐', 75, 35, '一罐330ml'),
  FoodInfo('果汁', 65, 30, '一杯250ml'),
  FoodInfo('豆浆', 35, 12, '一杯无糖250ml'),
  FoodInfo('牛奶', 30, 12, '一杯250ml'),
  FoodInfo('酸奶', 40, 15, '一杯无糖200g'),
  FoodInfo('苹果', 36, 20, '一个200g'),
  FoodInfo('香蕉', 52, 25, '一根150g'),
  FoodInfo('西瓜', 72, 20, '两牙500g'),
  FoodInfo('葡萄', 46, 25, '一小串150g'),
  FoodInfo('橙子', 43, 15, '一个200g'),
  FoodInfo('荔枝', 55, 25, '10颗'),
  FoodInfo('榴莲', 55, 40, '两房150g'),
  FoodInfo('花生', 15, 8, '一小把30g'),
  FoodInfo('汉堡', 65, 40, '一个'),
  FoodInfo('薯条', 75, 35, '一份100g'),
  FoodInfo('披萨', 60, 45, '两块'),
  FoodInfo('沙县', 65, 55, '一份拌面+汤'),
  FoodInfo('黄焖鸡米饭', 75, 60, '一份'),
  FoodInfo('麻辣烫', 60, 40, '一份荤素搭配'),
  FoodInfo('火锅', 55, 30, '一顿（涮菜肉为主）'),
  FoodInfo('烧烤', 55, 20, '一顿（肉串为主）'),
  FoodInfo('鸡蛋', 10, 1, '一个'),
  FoodInfo('豆腐', 15, 3, '一块200g'),
];

/// 一句话里找食物（子串匹配，最长优先，避免"米饭"误吞"黄焖鸡米饭"）
FoodInfo? lookupFood(String text) {
  final hits = lookupFoods(text);
  return hits.isEmpty ? null : hits.first;
}

List<FoodInfo> lookupFoods(String text) {
  final found = <FoodInfo>[];
  for (final f in foodTable) {
    if (text.contains(f.name)) found.add(f);
  }
  if (found.isEmpty && text.length >= 2) {
    // 反向兜底：用户只说了简称（"米饭"→"白米饭"）。
    // 取名字包含简称的候选项，按名字长度+库序排，最短通用项优先。
    final cands = <int>[];
    for (var i = 0; i < foodTable.length; i++) {
      if (foodTable[i].name.contains(text)) cands.add(i);
    }
    cands.sort((a, b) {
      final c = foodTable[a].name.length.compareTo(foodTable[b].name.length);
      return c != 0 ? c : a.compareTo(b);
    });
    if (cands.isNotEmpty) return [foodTable[cands.first]];
    return const [];
  }
  // 去掉被更长名字包含的短命中（"米饭" vs "黄焖鸡米饭"）
  found.sort((a, b) => b.name.length.compareTo(a.name.length));
  final kept = <FoodInfo>[];
  for (final f in found) {
    if (!kept.any((k) => k.name.contains(f.name))) kept.add(f);
  }
  return kept;
}

/// 预测餐后升幅（mmol/L）
double predictRiseMmolL({
  required double carbsG,
  required int gi,
  double? personalAvgRise,
}) {
  if (carbsG <= 0) return 0;
  final base = carbsG * (gi / 100) * 0.055;
  if (personalAvgRise == null) return base;
  return base * 0.5 + personalAvgRise * 0.5;
}
