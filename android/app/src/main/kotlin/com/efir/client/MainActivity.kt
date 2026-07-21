package com.efir.client

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var updateInstaller: UpdateInstaller? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updateInstaller = UpdateInstaller(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onDestroy() {
        updateInstaller?.dispose()
        updateInstaller = null
        super.onDestroy()
    }
}
