package com.example.split_together

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.PersistableBundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.text.Collator
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val appPickerWorker = Executors.newSingleThreadExecutor()
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
                "listApps" -> runPickerQuery(result) { listApps() }
                "appIcon" -> runPickerQuery(result) { value?.let(::appIcon) }
                "isAppAvailable" -> runPickerQuery(result) {
                    value != null && launchableIntent(value) != null
                }
                "openApp" -> {
                    val launch = value?.let(::launchableIntent)
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

    private fun runPickerQuery(result: MethodChannel.Result, query: () -> Any?) {
        appPickerWorker.execute {
            try {
                val value = query()
                runOnUiThread { result.success(value) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error("picker-unavailable", "無法讀取已安裝的 App", null)
                }
            }
        }
    }

    // Keep the existing launcher-only package visibility scope. Nothing is persisted.
    @Suppress("DEPRECATION")
    private fun listApps(): List<Map<String, String>> {
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val collator = Collator.getInstance()
        return packageManager.queryIntentActivities(query, 0)
            .filter { it.activityInfo.exported && it.activityInfo.packageName != packageName }
            .distinctBy { it.activityInfo.packageName }
            .mapNotNull {
                val id = it.activityInfo.packageName
                if (packageManager.getLaunchIntentForPackage(id) == null) return@mapNotNull null
                val label = it.loadLabel(packageManager).toString()
                    .replace(Regex("[\\p{Cntrl}\\s]+"), " ")
                    .trim().take(160)
                    .takeUnless { name -> name.isEmpty() || name == id }
                    ?: "未命名 App"
                mapOf("id" to id, "label" to label)
            }
            .sortedWith { a, b ->
                collator.compare(a.getValue("label"), b.getValue("label"))
                    .takeIf { it != 0 }
                    ?: a.getValue("id").compareTo(b.getValue("id"))
            }
    }

    @Suppress("DEPRECATION")
    private fun launchableIntent(id: String): Intent? {
        if (id == packageName || id.length > 255) return null
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(id)
        if (packageManager.queryIntentActivities(query, 0).none { it.activityInfo.exported }) {
            return null
        }
        return packageManager.getLaunchIntentForPackage(id)
    }

    // Icons are requested only for visible rows; cap both dimensions before encoding.
    private fun appIcon(id: String): ByteArray? {
        if (launchableIntent(id) == null) return null
        val icon = try {
            packageManager.getApplicationIcon(id)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        return try {
            icon.setBounds(0, 0, size, size)
            icon.draw(Canvas(bitmap))
            ByteArrayOutputStream().use { out ->
                if (bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) out.toByteArray() else null
            }
        } finally {
            bitmap.recycle()
        }
    }

    override fun onDestroy() {
        appPickerWorker.shutdownNow()
        super.onDestroy()
    }
}
