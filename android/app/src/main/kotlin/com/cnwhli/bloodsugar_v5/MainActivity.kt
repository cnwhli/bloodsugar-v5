package com.cnwhli.bloodsugar_v5

import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter

/// 直读手表/手机硬件传感器：心率 + 计步（不经过 Health Connect/欢太健康）。
///
/// 为什么走原生直读：
/// - 国产手表/手机（OPPO Watch X / 荣耀 Magic V2）没有谷歌框架，Health Connect
///   装不上；欢太健康也没有"同步到 Health Connect"开关，中转链路走不通。
/// - 心率（TYPE_HEART_RATE）+ 计步（TYPE_STEP_COUNTER）是硬件传感器，
///   App 直接读，链路最短，不费电（被动监听，不常开高频采样）。
class MainActivity : FlutterActivity() {

    private val bgListener = object : FlutterForegroundTaskLifecycleListener {
        override fun onEngineCreate(flutterEngine: FlutterEngine?) {
            if (flutterEngine != null) {
                try {
                    GeneratedPluginRegistrant.registerWith(flutterEngine)
                } catch (e: Exception) {
                    android.util.Log.e("BgPlugins", "register failed", e)
                }
            }
        }
        override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
        override fun onTaskRepeatEvent() {}
        override fun onTaskDestroy() {}
        override fun onEngineWillDestroy() {}
    }

    // ---- 硬件传感器直读 ----
    private var sensorManager: SensorManager? = null
    private var hrListener: SensorEventListener? = null
    private var stepListener: SensorEventListener? = null
    private var lastBpm: Int? = null
    private var lastSteps: Int? = null
    private var bootSteps: Int? = null // 今日步数 = 当前累计 - 当天首次累计

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(bgListener)
        sensorManager =
            getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        registerSensorChannels(flutterEngine)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        FlutterForegroundTaskPlugin.removeTaskLifecycleListener(bgListener)
        unregisterSensors()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun registerSensorChannels(engine: FlutterEngine) {
        // GlucoData 标准广播转发（pachi81/GlucoDataHandler 协议，MIT）：
        // action=glucodata.Minute，第三方表盘/车机/Tasker/xDrip+ 可订阅读数。
        MethodChannel(
            engine.dartExecutor.binaryMessenger, "bloodsugar/glucodata"
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            if (call.method == "broadcast") {
                try {
                    val i = Intent("glucodata.Minute")
                    i.putExtra(
                        "glucodata.Minute.mgdl",
                        (call.argument<Int>("mgdl") ?: 0),
                    )
                    i.putExtra(
                        "glucodata.Minute.glucose",
                        (call.argument<Number>("glucose")?.toFloat() ?: 0f),
                    )
                    i.putExtra(
                        "glucodata.Minute.Rate",
                        (call.argument<Number>("rate")?.toFloat() ?: 0f),
                    )
                    i.putExtra(
                        "glucodata.Minute.Time",
                        (call.argument<Number>("time")?.toLong() ?: 0L),
                    )
                    i.putExtra(
                        "glucodata.Minute.SerialNumber",
                        call.argument<String>("serial") ?: "",
                    )
                    i.putExtra(
                        "glucodata.Minute.Delta",
                        (call.argument<Number>("delta")?.toFloat() ?: 0f),
                    )
                    i.putExtra(
                        "glucodata.Minute.Alarm",
                        (call.argument<Int>("alarm") ?: 0),
                    )
                    sendBroadcast(i)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("BROADCAST_FAIL", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
        // 方法通道：一次读最新值 / 查传感器有没有
        MethodChannel(
            engine.dartExecutor.binaryMessenger, "watch_sensors/methods"
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "hasHeartRate" -> result.success(hasSensor(Sensor.TYPE_HEART_RATE))
                "hasStepCounter" ->
                    result.success(hasSensor(Sensor.TYPE_STEP_COUNTER))
                "latest" -> {
                    ensureListeners()
                    val map = HashMap<String, Any?>()
                    map["bpm"] = lastBpm
                    map["steps"] = todaySteps()
                    result.success(map)
                }
                else -> result.notImplemented()
            }
        }
        // 事件通道：心率变化实时推（手表抬腕即刷）
        EventChannel(
            engine.dartExecutor.binaryMessenger, "watch_sensors/heart_rate"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            var listener: SensorEventListener? = null
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                ensureListeners()
                val l = object : SensorEventListener {
                    override fun onSensorChanged(e: SensorEvent) {
                        val v = e.values.firstOrNull()?.toInt() ?: return
                        if (v > 0) {
                            lastBpm = v
                            sink.success(v)
                        }
                    }
                    override fun onAccuracyChanged(s: Sensor?, a: Int) {}
                }
                listener = l
                sensorManager?.registerListener(
                    l,
                    sensorManager?.getDefaultSensor(Sensor.TYPE_HEART_RATE),
                    SensorManager.SENSOR_DELAY_NORMAL,
                )
            }
            override fun onCancel(args: Any?) {
                listener?.let { sensorManager?.unregisterListener(it) }
                listener = null
            }
        })
    }

    private fun hasSensor(type: Int): Boolean {
        return try {
            val sm = sensorManager
                ?: (getSystemService(Context.SENSOR_SERVICE) as? SensorManager)
            sm?.getDefaultSensor(type) != null
        } catch (_: Exception) {
            false
        }
    }

    /// 常驻监听：计步器需要持续注册才能累积；心率读最新值即可。
    /// SENSOR_DELAY_NORMAL 最省电档，每步/每次心率变化才回调。
    private fun ensureListeners() {
        val sm = sensorManager ?: return
        if (stepListener == null && hasSensor(Sensor.TYPE_STEP_COUNTER)) {
            val l = object : SensorEventListener {
                override fun onSensorChanged(e: SensorEvent) {
                    val v = e.values.firstOrNull()?.toInt() ?: return
                    if (bootSteps == null) bootSteps = v
                    lastSteps = v
                }
                override fun onAccuracyChanged(s: Sensor?, a: Int) {}
            }
            stepListener = l
            sm.registerListener(
                l, sm.getDefaultSensor(Sensor.TYPE_STEP_COUNTER),
                SensorManager.SENSOR_DELAY_NORMAL,
            )
        }
        if (hrListener == null && hasSensor(Sensor.TYPE_HEART_RATE)) {
            val l = object : SensorEventListener {
                override fun onSensorChanged(e: SensorEvent) {
                    val v = e.values.firstOrNull()?.toInt() ?: return
                    if (v > 0) lastBpm = v
                }
                override fun onAccuracyChanged(s: Sensor?, a: Int) {}
            }
            hrListener = l
            // 心率是按需读：只注册拿最新值，不常驻高频（省电）
            sm.registerListener(
                l, sm.getDefaultSensor(Sensor.TYPE_HEART_RATE),
                SensorManager.SENSOR_DELAY_NORMAL,
            )
        }
    }

    /// 今日步数 = 开机累计 - 当天首次累计（跨天/重启自动归零重计）
    private fun todaySteps(): Int? {
        val cur = lastSteps ?: return null
        val base = bootSteps ?: return 0
        return (cur - base).coerceAtLeast(0)
    }

    private fun unregisterSensors() {
        hrListener?.let { sensorManager?.unregisterListener(it) }
        stepListener?.let { sensorManager?.unregisterListener(it) }
        hrListener = null
        stepListener = null
    }
}
