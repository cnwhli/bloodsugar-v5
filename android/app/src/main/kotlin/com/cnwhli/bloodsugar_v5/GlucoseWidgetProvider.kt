package com.cnwhli.bloodsugar_v5

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/// 手机桌面小组件：血糖大数字 + 趋势 + 时间 + 心率/步数。
///
/// 数据流：Flutter 侧每次收到新数 → HomeWidget.saveWidgetData 存 6 个字段 →
/// updateWidget 触发本 Provider.onUpdate → 读 SharedPreferences 刷 RemoteViews。
/// 桌面不需要开 App 也能看；点小组件直接进 App。
class GlucoseWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        // 桌面进程拉起 Provider 时 Flutter 侧一个字段都没存过也别崩：
        // 全包 try/catch，最坏显示 --，App 本体不受影响。
        try {
            doUpdate(context, appWidgetManager, appWidgetIds, widgetData)
        } catch (e: Exception) {
            android.util.Log.e("GlucoseWidget", "onUpdate failed", e)
        }
    }

    private fun doUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views =
                RemoteViews(context.packageName, R.layout.glucose_widget).apply {
                    // 点小组件进 App（MainActivity singleTop，直接回前台）
                    val pendingIntent =
                        HomeWidgetLaunchIntent.getActivity(
                            context,
                            MainActivity::class.java,
                        )
                    setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                    val value =
                        widgetData.getString("bg_value", null) ?: "--"
                    val trend =
                        widgetData.getString("bg_trend", null) ?: ""
                    setTextViewText(R.id.widget_value, value)
                    setTextViewText(R.id.widget_trend, trend)

                    val color =
                        widgetData.getInt("bg_color", 0xFF34C759.toInt())
                    setTextColor(R.id.widget_value, color)

                    val time =
                        widgetData.getString("bg_time", null)
                    if (time != null) {
                        setTextViewText(R.id.widget_time, time)
                        setViewVisibility(R.id.widget_time, View.VISIBLE)
                    } else {
                        setViewVisibility(R.id.widget_time, View.GONE)
                    }

                    // 心率/步数：空串=没数据，整行隐藏（别占地方）。
                    // Dart 侧不再传 null（部分 ROM 上 saveWidgetData null 闪退），
                    // 这里按 null 或空串都隐藏处理。
                    val hr = widgetData.getString("bg_hr", null)
                    val steps = widgetData.getString("bg_steps", null)
                    if (!hr.isNullOrEmpty() || !steps.isNullOrEmpty()) {
                        val line =
                            listOfNotNull(
                                hr?.let { "❤ $it" },
                                steps?.let { "👣 $it" },
                            ).joinToString("   ")
                        setTextViewText(R.id.widget_sport, line)
                        setViewVisibility(R.id.widget_sport, View.VISIBLE)
                    } else {
                        setViewVisibility(R.id.widget_sport, View.GONE)
                    }
                }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
