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

                    // 心率/步数：有就显示，没有整行隐藏（别占地方）
                    val hr = widgetData.getString("bg_hr", null)
                    val steps = widgetData.getString("bg_steps", null)
                    if (hr != null || steps != null) {
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
