package com.example.split_together

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

internal class FileBackupPicker(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: Request? = null

    private class Request(val reply: MethodChannel.Result, val exportBytes: ByteArray?) {
        val code get() = if (exportBytes == null) OPEN else SAVE
    }

    private class FileTooLarge : IOException()

    fun handle(call: MethodCall, reply: MethodChannel.Result) {
        if (pending != null) {
            reply.error("busy", null, null)
            return
        }
        val bytes: ByteArray?
        val intent: Intent
        when (call.method) {
            "open" -> {
                bytes = null
                // Providers may label transferred JSON as plain text or binary.
                // The snapshot codec validates the contents before showing a preview.
                intent = Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*")
            }
            "save" -> {
                bytes = call.argument<ByteArray>("bytes")
                val filename = call.argument<String>("filename")
                if (bytes == null || filename.isNullOrBlank()) {
                    reply.error("invalid-export", null, null)
                    return
                }
                if (bytes.size > MAX_BYTES) {
                    reply.error("too-large", null, null)
                    return
                }
                intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .setType("application/json")
                    .putExtra(Intent.EXTRA_TITLE, filename)
            }
            else -> {
                reply.notImplemented()
                return
            }
        }
        val request = Request(reply, bytes)
        pending = request
        try {
            activity.startActivityForResult(intent.addCategory(Intent.CATEGORY_OPENABLE), request.code)
        } catch (_: Exception) {
            pending = null
            reply.error("no-picker", null, null)
        }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != OPEN && code != SAVE) return false
        val request = pending ?: return true
        if (request.code != code) return true
        if (resultCode == Activity.RESULT_CANCELED) {
            pending = null
            request.reply.success(if (code == SAVE) false else null)
            return true
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT) {
            pending = null
            request.reply.error("file-unavailable", null, null)
            return true
        }
        worker.execute {
            try {
                val bytes = request.exportBytes
                val answer = if (bytes == null) {
                    readDocument(uri)
                } else {
                    val stream = activity.contentResolver.openOutputStream(uri, "wt") ?: throw IOException()
                    stream.use { it.write(bytes) }
                    true
                }
                finish(request) { it.success(answer) }
            } catch (_: FileTooLarge) {
                finish(request) { it.error("too-large", null, null) }
            } catch (_: Exception) {
                finish(request) { it.error("file-unavailable", null, null) }
            }
        }
        return true
    }

    private fun readDocument(uri: Uri): ByteArray {
        val resolver = activity.contentResolver
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column) && cursor.getLong(column) > MAX_BYTES) {
                throw FileTooLarge()
            }
        }
        val stream = resolver.openInputStream(uri) ?: throw IOException()
        return stream.use { input ->
            val out = ByteArrayOutputStream(DEFAULT_BUFFER_SIZE)
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            // Unknown or stale document sizes still respect the cap. Probe at most one extra byte.
            while (true) {
                val remaining = MAX_BYTES - out.size()
                val count = input.read(buffer, 0, minOf(buffer.size, remaining + 1))
                if (count == -1) break
                if (count > remaining) throw FileTooLarge()
                out.write(buffer, 0, count)
            }
            out.toByteArray()
        }
    }

    private fun finish(request: Request, deliver: (MethodChannel.Result) -> Unit) {
        activity.runOnUiThread {
            if (pending === request) {
                pending = null
                deliver(request.reply)
            }
        }
    }

    fun close() {
        pending?.reply?.error("interrupted", null, null)
        pending = null
        worker.shutdownNow()
    }

    private companion object {
        const val OPEN = 0x5F01
        const val SAVE = 0x5F02
        // Keep in step with the v1 ledger snapshot limit (LedgerBackup.maxBytes).
        const val MAX_BYTES = 32 * 1024 * 1024
    }
}
