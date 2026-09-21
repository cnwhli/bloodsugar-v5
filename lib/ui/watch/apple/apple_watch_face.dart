// Apple Watch 表盘 Glucose Complication
// 平台：watchOS
// 实现语言：Swift（需 Xcode 工程）
// 数据源：Supabase Realtime
//
// 使用方法：
// 1. 在 Xcode 中创建 Watch App Target
// 2. 启用 ClockKit Complication
// 3. 将以下 Swift 代码复制到 ComplicationController.swift
// 4. 替换 SUPABASE_URL 和 SUPABASE_ANON_KEY

/*
import ClockKit
import Supabase

class ComplicationController: NSObject, CLKComplicationDataSource {
    let supabase = SupabaseClient(
        url: URL(string: "https://YOUR_PROJECT.supabase.co")!,
        apiKey: "YOUR_ANON_KEY"
    )

    // 当前血糖值（缓存）
    var currentGlucose: Double?
    var currentTrend: Int = 0
    var isLow: Bool = false

    // MARK: - Timeline Configuration

    func getCurrentTimelineEntry(for complication: CLKComplication,
                                  withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        let entry = makeEntry(for: complication)
        handler(entry)
    }

    func requestUpdate(for complication: CLKComplication) {
        // 实时更新：每 1 分钟拉取一次
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            self.fetchGlucose { _ in
                CLKComplicationServer.sharedInstance().reloadTimeline(for: complication)
            }
        }
    }

    // MARK: - Data Fetching

    func fetchGlucose(completion: @escaping (Bool) -> Void) {
        // 从 Supabase 读取最新血糖
        // let task = supabase.from("glucose_readings")
        //     .select("value_mmol_l, trend, brand, created_at")
        //     .order("created_at", ascending: false)
        //     .limit(1)
        //     .execute()
        //
        // guard let data = try? task.value else { completion(false); return }
        // self.currentGlucose = data["value_mmol_l"].double
        // self.currentTrend = data["trend"].int ?? 0
        // self.isLow = (self.currentGlucose ?? 100) < 3.9
        completion(true)
    }

    // MARK: - Complication Template

    func makeEntry(for complication: CLKComplication) -> CLKComplicationTimelineEntry {
        let template: CLKComplicationTemplate

        switch complication.family {
        case .modularSmall:
            let modSmall = CLKComplicationTemplateModularSmallStackText()
            modSmall.line1TextProvider = CLKSimpleTextProvider(text: gaugeText)
            modSmall.line2TextProvider = CLKSimpleTextProvider(text: trendLabel)
            template = modSmall

        case .utilitarianSmall:
            let utilSmall = CLKComplicationTemplateUtilitarianSmallFlat()
            utilSmall.textProvider = CLKSimpleTextProvider(text: gaugeText)
            template = utilSmall

        case .graphicCorner:
            let corner = CLKComplicationTemplateGraphicCornerStackText()
            corner.topTextProvider = CLKSimpleTextProvider(text: gaugeText)
            corner.bottomTextProvider = CLKSimpleTextProvider(text: trendLabel)
            template = corner

        default:
            let simple = CLKComplicationTemplateModularSmallStackText()
            simple.line1TextProvider = CLKSimpleTextProvider(text: gaugeText)
            simple.line2TextProvider = CLKSimpleTextProvider(text: trendLabel)
            template = simple
        }

        // 低血糖红色高亮
        if isLow {
            // 修改模板颜色为红色
        }

        let entry = CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template)
        return entry
    }

    var gaugeText: String {
        guard let gl = currentGlucose else { return "--" }
        return String(format: "%.0f", gl)
    }

    var trendLabel: String {
        switch currentTrend {
        case 0: return "→"
        case 1: return "↗"
        case 2: return "↗↑"
        case 3: return "↘"
        case 4: return "↘↓"
        default: return "--"
        }
    }
}
*/

import 'package:flutter/material.dart';

/// Apple Watch 表盘配置（Flutter 侧）
/// 实际表盘需用 Swift 实现，Flutter 侧仅提供数据模型
class AppleWatchFace {
  /// 表盘 complication 类型
  static const List<String> supportedFamilies = [
    'modularSmall',
    'utilitarianSmall',
    'graphicCorner',
    'graphicRectangular',
  ];

  /// 低血糖显示：红色背景 + 闪烁
  static const bool highlightLowGlucose = true;

  /// 实时更新间隔（秒）
  static const int updateInterval = 60;
}
