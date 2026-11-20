package com.example.split_together

import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.PersistableBundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.Collator

class MainActivity : FlutterActivity() {
    private var appPicker: AlertDialog? = null
    private val officialPackages = setOf(
        "com.chinatrust.mobilebank", "tw.com.taishinbank.mobile", "tw.gov.post.mpost"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "split_together/bank_launcher")
            .setMethodCallHandler(::handleBankAction)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "split_together/meal_share")
            .setMethodCallHandler(::handleMealShare)
    }

    private fun handleMealShare(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "shareText") {
            result.notImplemented()
            return
        }
        val text = call.arguments as? String
        if (text.isNullOrBlank()) {
            result.error("empty-list", "沒有可分享的聚餐清單", null)
            return
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        if (startIfAvailable(Intent.createChooser(send, null))) {
            result.success(null)
        } else {
            result.error("share-unavailable", "無法開啟系統分享選單", null)
        }
    }

    private fun handleBankAction(call: MethodCall, result: MethodChannel.Result) {
        val value = call.arguments as? String
        try {
            when (call.method) {
                "pickApp" -> pickApp(result)
                "openApp" -> {
                    val launch = value?.takeIf { it != packageName }
                        ?.let { packageManager.getLaunchIntentForPackage(it) }
                    result.success(startIfAvailable(launch))
                }
                "openOfficialPage" -> {
                    val link = if (value in officialPackages) {
                        Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=" + value))
                    } else null
                    result.success(startIfAvailable(link))
                }
                "copyAccount" -> {
                    if (value == null || !Regex("[0-9]{6,20}").matches(value)) {
                        result.error("invalid-account", "帳號格式不正確", null)
                        return
                    }
                    val clip = ClipData.newPlainText("收款帳號", value)
                    clip.description.extras = PersistableBundle().apply {
                        putBoolean("android.content.extra.IS_SENSITIVE", true)
                    }
                    getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: SecurityException) {
            result.error("not-allowed", "裝置未允許此操作", null)
        }
    }

    private fun startIfAvailable(intent: Intent?): Boolean {
        if (intent == null) return false
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    // Only list activities with a launcher icon, and only when the user opens this picker.
    @Suppress("DEPRECATION")
    private fun pickApp(result: MethodChannel.Result) {
        if (appPicker != null) {
            result.error("picker-busy", "已開啟 App 選擇器", null)
            return
        }
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val collator = Collator.getInstance()
        val choices = packageManager.queryIntentActivities(query, 0)
            .filter { it.activityInfo.exported && it.activityInfo.packageName != packageName }
            .map {
                val id = it.activityInfo.packageName
                val label = it.loadLabel(packageManager).toString().trim().ifEmpty { id }
                id to label
            }
            .distinctBy { it.first }
            .sortedWith { a, b -> collator.compare(a.second, b.second) }
        if (choices.isEmpty()) {
            result.error("no-apps", "裝置上沒有可選擇的 App", null)
            return
        }
        var selection: Map<String, String>? = null
        val labels = choices.map { (id, name) -> "$name\n$id" }.toTypedArray()
        val dialog = AlertDialog.Builder(this)
            .setTitle("選擇轉帳用的 App")
            .setItems(labels) { _, index ->
                val (id, label) = choices[index]
                selection = mapOf("id" to id, "label" to label)
            }
            .setNegativeButton("取消", null)
            .create()
        appPicker = dialog
        dialog.setOnDismissListener {
            appPicker = null
            result.success(selection)
        }
        dialog.show()
    }

    override fun onDestroy() {
        appPicker?.dismiss()
        super.onDestroy()
    }
}
