package com.dhivalabs.secure_shell_go

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * "Save to…": the system document UI's `ACTION_CREATE_DOCUMENT`, so the user
 * can put a file in any folder of any installed document provider — internal
 * storage, an SD card, Google Drive, OneDrive, Dropbox, Nextcloud — and the
 * bytes Dart sent are written there. The Dart half is
 * `MethodChannelDeviceStorage.saveDocument` in `device_storage.dart`.
 *
 * Reached through [StorageBridge]'s channel (method `saveDocument`) and its
 * activity-result routing, so `MainActivity` needs no change for it.
 *
 * Made for backups, which are kilobytes to a few megabytes: the bytes come in
 * the one call and wait here while the picker is open, rather than streaming
 * through [StorageBridge]'s chunked download path. [MAX_BYTES] keeps anything
 * larger off this path.
 *
 * No `takePersistableUriPermission`: the grant that comes with the result is
 * used once, to write, and allowed to lapse — the same policy as the pickers.
 */
class DocumentSaver(private val activity: Activity) {

    companion object {
        /**
         * Distinct from StorageBridge's (0x5347, 0x5348), MainActivity's
         * (0x5350) and AppLockBridge's (0x5351) codes.
         */
        const val REQUEST_SAVE_DOCUMENT = 0x5349

        /** This path holds the whole file in memory. */
        const val MAX_BYTES = 64 * 1024 * 1024
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** The call waiting on the picker; also the guard against a second one. */
    private var pending: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    fun save(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "A save dialog is already open.", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("bad_args", "Nothing to save.", null)
            return
        }
        if (bytes.size > MAX_BYTES) {
            result.error("too_large", "That file is too large to save this way.", null)
            return
        }
        val name = call.argument<String>("fileName")?.takeIf { it.isNotBlank() }
            ?: "secureshellgo-backup"
        val mime = call.argument<String>("mimeType")?.takeIf { it.isNotBlank() }
            ?: "application/octet-stream"

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        pending = result
        pendingBytes = bytes
        try {
            activity.startActivityForResult(intent, REQUEST_SAVE_DOCUMENT)
        } catch (e: Throwable) {
            pending = null
            pendingBytes = null
            result.error("no_picker", "No app on this device can save files.", null)
        }
    }

    /** Returns true when this saver owned the result. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_SAVE_DOCUMENT) return false
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        val result = pending
        if (result == null) {
            // The activity was recreated while the picker was open (a
            // rotation, or the process stopped and brought back): the call
            // that asked and its bytes went with the old one, whose dispose()
            // already told Dart "not saved". The provider made the document
            // anyway when the user confirmed, so it is removed rather than
            // left behind as an empty file that looks like a backup.
            if (uri != null) {
                runCatching { io.execute { deleteIfEmpty(uri) } }
            }
            return true
        }
        val bytes = pendingBytes
        pending = null
        pendingBytes = null

        if (uri == null || bytes == null) {
            // Backed out of the picker.
            result.success(null)
            return true
        }
        io.execute {
            // Usually a document the provider has just created — an existing
            // name gets a new one, "backup (1)" — but a provider may instead
            // hand back an existing document the user chose to replace. Only
            // one that was empty before this wrote to it is this attempt's to
            // remove if the write fails.
            val fresh = isEmptyDocument(uri)
            try {
                write(uri, bytes)
                val name = displayName(uri) ?: uri.lastPathSegment ?: "backup"
                main.post {
                    result.success(mapOf("displayName" to name, "uri" to uri.toString()))
                }
            } catch (e: Throwable) {
                if (fresh) {
                    runCatching { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
                }
                main.post { result.error("save_failed", e.message ?: e.toString(), null) }
            }
        }
        return true
    }

    /**
     * True only when the provider reports the document as zero bytes. A size
     * it does not report is not taken for empty: deleting is the one thing
     * here that cannot be undone.
     */
    private fun isEmptyDocument(uri: Uri): Boolean = runCatching {
        activity.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            cursor.moveToFirst() && !cursor.isNull(0) && cursor.getLong(0) == 0L
        } ?: false
    }.getOrDefault(false)

    private fun deleteIfEmpty(uri: Uri) {
        if (isEmptyDocument(uri)) {
            runCatching { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
        }
    }

    /**
     * "wt" truncates as well as writes, which matters when the provider
     * handed back an existing document: its old contents must not outlast
     * the new ones. Not every provider takes it, so "w" is the fallback; a
     * fresh document has nothing older inside it to leave behind.
     */
    private fun write(uri: Uri, bytes: ByteArray) {
        val resolver = activity.contentResolver
        val out: OutputStream = runCatching { resolver.openOutputStream(uri, "wt") }
            .getOrNull()
            ?: resolver.openOutputStream(uri, "w")
            ?: throw IllegalStateException("The provider would not open that file for writing.")
        out.use {
            it.write(bytes)
            it.flush()
        }
    }

    private fun displayName(uri: Uri): String? = runCatching {
        activity.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    }.getOrNull()

    fun dispose() {
        // An activity going away with the picker open must not leave the Dart
        // future waiting forever.
        val result = pending
        pending = null
        pendingBytes = null
        if (result != null) runCatching { result.success(null) }
        io.shutdown()
    }
}
