package com.efir.client

import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Установка обновления клиента на Android.
 *
 * Два пути, и разница между ними принципиальна для signage:
 *  * приложение — **Device Owner** → PackageInstaller ставит APK молча, экран
 *    обновляется сам, никто не подходит к телевизору;
 *  * обычная установка → система показывает диалог подтверждения. Для стены
 *    экранов это тупик, поэтому мы честно возвращаем в панель статус
 *    `needs_confirmation`, а не делаем вид, что обновление поехало.
 *
 * Device Owner включается только на свежесброшенном устройстве без аккаунтов
 * (`adb shell dpm set-device-owner com.efir.client/...`), задним числом — никак.
 */
class UpdateInstaller(private val context: Context, messenger: BinaryMessenger) {

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler { call, result ->
            when (call.method) {
                "isDeviceOwner" -> result.success(isDeviceOwner())
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "path is required", null)
                    } else {
                        install(File(path), result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private var pendingResult: MethodChannel.Result? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(
                PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_FAILURE,
            )
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
            when (status) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    // Не Device Owner: система хочет подтверждение человеком.
                    // Диалог всё равно показываем (вдруг у экрана есть оператор),
                    // но в панель уходит честный статус.
                    val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    }
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    confirm?.let { runCatching { context.startActivity(it) } }
                    finish("needs_confirmation", message)
                }
                PackageInstaller.STATUS_SUCCESS -> finish("success", message)
                else -> finish("failed", message.ifBlank { "install status $status" })
            }
        }
    }

    init {
        val filter = IntentFilter(ACTION_INSTALL_RESULT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    fun dispose() {
        runCatching { context.unregisterReceiver(receiver) }
        channel.setMethodCallHandler(null)
        pendingResult = null
    }

    private fun isDeviceOwner(): Boolean {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        return dpm?.isDeviceOwnerApp(context.packageName) == true
    }

    private fun finish(status: String, message: String) {
        val result = pendingResult ?: return
        pendingResult = null
        result.success(mapOf("status" to status, "message" to message))
    }

    private fun install(apk: File, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "another install is already running", null)
            return
        }
        if (!apk.isFile) {
            result.error("not_found", "apk not found: ${apk.path}", null)
            return
        }
        pendingResult = result

        try {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                params.setRequireUserAction(
                    PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED,
                )
            }
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                // Пишем APK прямо в сессию: не нужен ни FileProvider, ни
                // content-URI, ни доступ установщика к нашему каталогу.
                session.openWrite(APK_NAME, 0, apk.length()).use { output ->
                    apk.inputStream().use { input -> input.copyTo(output) }
                    session.fsync(output)
                }

                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        PendingIntent.FLAG_MUTABLE
                    } else {
                        0
                    }
                val callback = PendingIntent.getBroadcast(
                    context,
                    sessionId,
                    Intent(ACTION_INSTALL_RESULT).setPackage(context.packageName),
                    flags,
                )
                session.commit(callback.intentSender)
            }
        } catch (e: Exception) {
            pendingResult = null
            result.error("install_failed", e.message ?: e.toString(), null)
        }
    }

    companion object {
        const val CHANNEL = "efir/update_installer"
        private const val APK_NAME = "efir-update.apk"
        private const val ACTION_INSTALL_RESULT = "com.efir.client.INSTALL_RESULT"
    }
}
