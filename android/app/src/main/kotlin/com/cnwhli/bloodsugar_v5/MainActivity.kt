package com.cnwhli.bloodsugar_v5

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter

class MainActivity : FlutterActivity() {

    // 后台 isolate 的引擎诞生时，把全部插件（含 flutter_blue_plus / sqflite /
    // shared_preferences / health / overlay）注册进去。
    // 不做这一步：后台收数 isolate 里扫得到广播也写不进库，
    // 表现就是"一点开App就有数、放后台就断"。
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(bgListener)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        FlutterForegroundTaskPlugin.removeTaskLifecycleListener(bgListener)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
