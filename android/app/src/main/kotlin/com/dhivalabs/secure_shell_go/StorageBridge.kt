package com.dhivalabs.secure_shell_go

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Bridges the two things a pure-Dart SSH client cannot do itself: write a
 * downloaded file into the *shared* Downloads collection so it shows up in the
 * user's file manager, and hand back a local copy of a file the user picked
 * through the system document UI.
 *
 * Written as a ~250-line channel rather than pulled in as a plugin on purpose.
 * The plugins in this space either buffer the whole file in memory before
 * handing it to MediaStore, or stage it in app-private storage and copy
 * afterwards — neither is acceptable for a multi-gigabyte `scp`. Here the SFTP
 * stream is written straight into the MediaStore `OutputStream` chunk by
 * chunk, with the Dart side awaiting each write, so backpressure reaches all
 * the way back to the SSH channel and memory use stays flat. It also keeps the
 * dependency count at zero on a toolchain (AGP 9 / Kotlin 2.3) that has been
 * unkind to file-picking plugins.
 */
class StorageBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.dhivalabs.secure_shell_go/storage"
        const val SHARE_CHANNEL = "com.dhivalabs.secure_shell_go/share"
        const val REQUEST_PICK_FILE = 0x5347
        const val REQUEST_WRITE_PERMISSION = 0x5348

        /** Default cap for [pickFileContent] when Dart does not send one. */
        const val DEFAULT_CONTENT_PICK_MAX_BYTES = 64L * 1024L

        /**
         * How long a staged upload batch is kept before a later staging
         * sweeps it away. Long enough that a slow upload of a big file is
         * never pulled out from under itself, short enough that the cache
         * does not accumulate every video the user ever shared.
         */
        private const val STAGING_TTL_MS = 6L * 60L * 60L * 1000L

        /** Depth cap on a download's relative path — see [sanitiseRelativePath]. */
        private const val MAX_RELATIVE_SEGMENTS = 16

        private const val LEGACY_WRITE = android.Manifest.permission.WRITE_EXTERNAL_STORAGE
        private val usesMediaStore = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    /** What to do with the document once the picker returns. */
    private enum class PickMode { STAGE, STAGE_MULTIPLE, CONTENT }

    /** Thrown by [readFileContent] when the picked document exceeds its cap. */
    private class FileTooLargeException(message: String) : Exception(message)

    /** One in-flight download. Exactly one of [uri]/[file] is set. */
    private class Sink(
        val out: OutputStream,
        val uri: Uri?,
        val file: File?,
        var displayName: String,
    )

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val sinks = HashMap<Int, Sink>()
    private val nextId = AtomicInteger(1)

    private var pendingPick: MethodChannel.Result? = null
    private var pendingPickMode: PickMode = PickMode.STAGE
    private var pendingMaxBytes: Long = DEFAULT_CONTENT_PICK_MAX_BYTES
    private var pendingPermission: MethodChannel.Result? = null

    /**
     * URIs handed to us by another app's Share menu, waiting for Dart to ask
     * for them. Held as URIs rather than staged copies because a share can
     * arrive during a cold start — staging a 2 GB video before the first
     * frame would look like the app failing to launch.
     */
    private val pendingShare = ArrayList<Uri>()

    fun dispose() {
        io.execute {
            for (sink in sinks.values) {
                runCatching { sink.out.close() }
            }
            sinks.clear()
        }
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermission" -> ensurePermission(result)
            "downloadExists" -> {
                val name = call.argument<String>("fileName") ?: ""
                val relative = sanitiseRelativePath(call.argument<String>("relativePath"))
                onIo(result) { downloadExists(name, relative) }
            }
            "beginDownload" -> {
                val name = call.argument<String>("fileName") ?: "download"
                val mime = call.argument<String>("mimeType")
                val overwrite = call.argument<Boolean>("overwrite") ?: false
                val relative = sanitiseRelativePath(call.argument<String>("relativePath"))
                onIo(result) { beginDownload(name, mime, overwrite, relative) }
            }
            "openDownload" -> result.success(
                openDownload(
                    call.argument<String>("uri").orEmpty(),
                    call.argument<String>("mimeType"),
                ),
            )
            "writeChunk" -> {
                val id = call.argument<Int>("id") ?: -1
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                onIo(result) { writeChunk(id, bytes) }
            }
            "finishDownload" -> {
                val id = call.argument<Int>("id") ?: -1
                onIo(result) { finishDownload(id) }
            }
            "abortDownload" -> {
                val id = call.argument<Int>("id") ?: -1
                onIo(result) { abortDownload(id) }
            }
            "pickFile" -> pickFile(result)
            "pickFiles" -> launchPicker(
                result,
                PickMode.STAGE_MULTIPLE,
                DEFAULT_CONTENT_PICK_MAX_BYTES,
            )
            "pickFileContent" -> {
                val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                    ?: DEFAULT_CONTENT_PICK_MAX_BYTES
                pickFileContent(result, maxBytes)
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [work] off the main thread and replies on it. */
    private fun onIo(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("storage_error", e.message ?: e.toString(), null) }
            }
        }
    }

    // ---------------------------------------------------------------- permission

    private fun ensurePermission(result: MethodChannel.Result) {
        // Scoped storage (API 29+) needs no permission at all to contribute to
        // the Downloads collection — that is the whole point of it.
        if (usesMediaStore) {
            result.success(true)
            return
        }
        if (activity.checkSelfPermission(LEGACY_WRITE) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.error("busy", "A permission request is already in flight.", null)
            return
        }
        pendingPermission = result
        activity.requestPermissions(arrayOf(LEGACY_WRITE), REQUEST_WRITE_PERMISSION)
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_WRITE_PERMISSION) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
        return true
    }

    // ----------------------------------------------------------------- downloads

    /**
     * Reduces a caller-supplied relative path to something that cannot
     * escape `Download/`.
     *
     * Every segment of a recursive download's path came out of a remote
     * directory listing, which is to say out of the server's hands: `..`,
     * absolute paths, separators smuggled inside a name and control
     * characters are all dropped rather than escaped. Dart sanitises this too
     * (`RemotePath.sanitiseRelativeDirectory`) — twice on purpose, since this
     * is the side where getting it wrong writes outside the folder the user
     * agreed to.
     *
     * Returns "" for "straight into Downloads".
     */
    private fun sanitiseRelativePath(raw: String?): String {
        if (raw.isNullOrEmpty()) return ""
        val segments = ArrayList<String>()
        for (part in raw.split('/')) {
            if (segments.size >= MAX_RELATIVE_SEGMENTS) break
            val trimmed = part.trim()
            if (trimmed.isEmpty() || trimmed == "." || trimmed == "..") continue
            var cleaned = trimmed
                .map { c -> if (c.isISOControl() || c in "\\/:*?\"<>|") '_' else c }
                .joinToString("")
                .trim()
                .trimStart('.')
                .trimEnd('.', ' ')
            if (cleaned.isEmpty()) continue
            if (cleaned.length > 80) cleaned = cleaned.substring(0, 80)
            segments.add(cleaned)
        }
        return segments.joinToString("/")
    }

    private fun legacyDownloadDir(relativePath: String = ""): File {
        var dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (relativePath.isNotEmpty()) dir = File(dir, relativePath)
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /** MediaStore stores RELATIVE_PATH with a trailing separator. */
    private fun mediaStoreRelativePath(relativePath: String): String =
        if (relativePath.isEmpty()) {
            "${Environment.DIRECTORY_DOWNLOADS}/"
        } else {
            "${Environment.DIRECTORY_DOWNLOADS}/$relativePath/"
        }

    /**
     * Whether a download of this name is already there.
     *
     * On API 29+ this only sees files this app contributed: scoped storage
     * hides other apps' entries without a media permission we deliberately do
     * not ask for. That is the case that matters — the same file downloaded
     * twice — and being wrong the other way just means MediaStore does its own
     * de-duplication, which the caller reads back anyway.
     */
    private fun downloadExists(fileName: String, relativePath: String): Boolean {
        if (!usesMediaStore) {
            return File(legacyDownloadDir(relativePath), fileName).exists()
        }
        val projection = arrayOf(MediaStore.Downloads._ID)
        activity.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Downloads.DISPLAY_NAME} = ? AND " +
                "${MediaStore.Downloads.RELATIVE_PATH} = ?",
            arrayOf(fileName, mediaStoreRelativePath(relativePath)),
            null,
        )?.use { cursor ->
            return cursor.count > 0
        }
        return false
    }

    private fun deleteExistingDownload(fileName: String, relativePath: String) {
        if (!usesMediaStore) {
            File(legacyDownloadDir(relativePath), fileName).delete()
            return
        }
        activity.contentResolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.Downloads.DISPLAY_NAME} = ? AND " +
                "${MediaStore.Downloads.RELATIVE_PATH} = ?",
            arrayOf(fileName, mediaStoreRelativePath(relativePath)),
        )
    }

    private fun beginDownload(
        fileName: String,
        mimeType: String?,
        overwrite: Boolean,
        relativePath: String,
    ): Map<String, Any?> {
        if (overwrite) deleteExistingDownload(fileName, relativePath)

        val id = nextId.getAndIncrement()

        if (!usesMediaStore) {
            var target = File(legacyDownloadDir(relativePath), fileName)
            if (!overwrite) target = uniqueLegacyFile(target)
            val out = FileOutputStream(target)
            sinks[id] = Sink(out, null, target, target.name)
            return mapOf("id" to id, "displayName" to target.name)
        }

        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            if (!mimeType.isNullOrEmpty()) {
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
            }
            // RELATIVE_PATH is what creates Download/<dirname>/<subdir>/ for a
            // recursive download; MediaStore makes the directories itself.
            put(MediaStore.Downloads.RELATIVE_PATH, mediaStoreRelativePath(relativePath))
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val resolver = activity.contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Downloads is not writable on this device.")
        val out = resolver.openOutputStream(uri)
            ?: throw IllegalStateException("Could not open the download for writing.")

        // MediaStore may have renamed around a collision; report what it chose
        // rather than what we asked for.
        val actualName = queryDisplayName(uri) ?: fileName
        sinks[id] = Sink(out, uri, null, actualName)
        return mapOf("id" to id, "displayName" to actualName)
    }

    private fun uniqueLegacyFile(target: File): File {
        if (!target.exists()) return target
        val name = target.name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var n = 1
        while (n < 10_000) {
            val candidate = File(target.parentFile, "$stem ($n)$ext")
            if (!candidate.exists()) return candidate
            n++
        }
        return File(target.parentFile, "$stem (${System.currentTimeMillis()})$ext")
    }

    private fun writeChunk(id: Int, bytes: ByteArray): Any? {
        val sink = sinks[id] ?: throw IllegalStateException("Download $id is not open.")
        sink.out.write(bytes)
        return null
    }

    private fun finishDownload(id: Int): Map<String, Any?> {
        val sink = sinks.remove(id)
            ?: throw IllegalStateException("Download $id is not open.")
        sink.out.flush()
        sink.out.close()

        val uri = sink.uri
        if (uri != null) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            activity.contentResolver.update(uri, values, null, null)
            sink.displayName = queryDisplayName(uri) ?: sink.displayName
            return mapOf("displayName" to sink.displayName, "uri" to uri.toString())
        }

        val file = sink.file
        if (file != null) {
            // Pre-Q the file is invisible to the Downloads UI until the media
            // scanner has seen it.
            MediaScannerConnection.scanFile(activity, arrayOf(file.absolutePath), null, null)
            return mapOf("displayName" to file.name, "uri" to Uri.fromFile(file).toString())
        }
        return mapOf("displayName" to sink.displayName, "uri" to null)
    }

    private fun abortDownload(id: Int): Any? {
        val sink = sinks.remove(id) ?: return null
        runCatching { sink.out.close() }
        // A cancelled download must not leave a truncated file sitting in the
        // user's Downloads looking complete.
        sink.uri?.let { runCatching { activity.contentResolver.delete(it, null, null) } }
        sink.file?.let { runCatching { it.delete() } }
        return null
    }

    private fun queryDisplayName(uri: Uri): String? {
        activity.contentResolver.query(
            uri,
            arrayOf(MediaStore.Downloads.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return null
    }

    /**
     * Hands a finished download to whatever app can show it, through the
     * system chooser.
     *
     * The read grant rides on the intent: this app inserted the MediaStore
     * row, so it owns it and can pass access to the app the user picks
     * without either side needing a storage permission. Pre-Q downloads land
     * as `file://`, which cannot be handed to another app without a
     * FileProvider — rather than add one for a path that only exists on API
     * 23–28, this reports false and the caller keeps quiet about "Open".
     */
    private fun openDownload(uriString: String, mimeType: String?): Boolean {
        if (uriString.isEmpty()) return false
        val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return false
        if (uri.scheme != "content") return false

        val type = mimeType?.takeIf { it.isNotEmpty() }
            ?: activity.contentResolver.getType(uri)
            ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(view, "Open with").apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return runCatching { activity.startActivity(chooser) }.isSuccess
    }

    // --------------------------------------------------------------- share sheet

    /**
     * Records the files behind an `ACTION_SEND`/`ACTION_SEND_MULTIPLE`
     * intent, if this is one. Returns whether it was.
     */
    fun recordSharedIntent(intent: Intent?): Boolean {
        val uris = sharedUris(intent)
        if (uris.isEmpty()) return false
        synchronized(pendingShare) {
            pendingShare.clear()
            pendingShare.addAll(uris)
        }
        return true
    }

    /** Stages and hands over whatever share is waiting. Null if none is. */
    fun takePendingShare(result: MethodChannel.Result) {
        val uris = synchronized(pendingShare) {
            val copy = ArrayList(pendingShare)
            pendingShare.clear()
            copy
        }
        if (uris.isEmpty()) {
            result.success(null)
            return
        }
        onIo(result) { stageBatch(uris) }
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val tiramisu = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (tiramisu) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                }
                listOfNotNull(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = if (tiramisu) {
                    intent.getParcelableArrayListExtra(
                        Intent.EXTRA_STREAM,
                        Uri::class.java,
                    )
                } else {
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                }
                uris.orEmpty().filterNotNull()
            }
            else -> emptyList()
        }
    }

    // ------------------------------------------------------------------- picking

    private fun pickFile(result: MethodChannel.Result) {
        launchPicker(result, PickMode.STAGE, DEFAULT_CONTENT_PICK_MAX_BYTES)
    }

    /**
     * Same picker as [pickFile], but for something small enough to belong in
     * a form field (an imported private key) rather than an upload: the
     * document's content is read straight into memory as text and returned,
     * capped at [maxBytes], instead of being copied into app cache. Nothing
     * is written to disk on this path.
     */
    private fun pickFileContent(result: MethodChannel.Result, maxBytes: Long) {
        launchPicker(result, PickMode.CONTENT, maxBytes)
    }

    private fun launchPicker(result: MethodChannel.Result, mode: PickMode, maxBytes: Long) {
        if (pendingPick != null) {
            result.error("busy", "A file picker is already open.", null)
            return
        }
        pendingPick = result
        pendingPickMode = mode
        pendingMaxBytes = maxBytes
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (mode == PickMode.STAGE_MULTIPLE) {
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
        try {
            activity.startActivityForResult(intent, REQUEST_PICK_FILE)
        } catch (e: Throwable) {
            pendingPick = null
            result.error("no_picker", "No app on this device can pick files.", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_FILE) return false
        val pending = pendingPick ?: return true
        val mode = pendingPickMode
        val maxBytes = pendingMaxBytes
        pendingPick = null

        val uris = if (resultCode == Activity.RESULT_OK) pickedUris(data) else emptyList()
        if (uris.isEmpty()) {
            // A cancelled multi-pick is an empty batch rather than null, so
            // Dart's "the user backed out" branch is the same shape as its
            // "nothing selected" one.
            pending.success(if (mode == PickMode.STAGE_MULTIPLE) mapOf("files" to emptyList<Any>()) else null)
            return true
        }

        // Note: we never call takePersistableUriPermission on these URIs, in
        // any mode. The grant that comes with ACTION_OPEN_DOCUMENT's
        // result lives only as long as this activity result is being
        // handled — read it now (staged to cache, or straight into memory
        // below) and let it lapse rather than holding onto SAF access the
        // app has no ongoing use for.
        io.execute {
            try {
                val payload = when (mode) {
                    PickMode.STAGE -> stageForUpload(uris.first())
                    PickMode.STAGE_MULTIPLE -> stageBatch(uris)
                    PickMode.CONTENT -> readFileContent(uris.first(), maxBytes)
                }
                main.post { pending.success(payload) }
            } catch (e: FileTooLargeException) {
                main.post { pending.error("too_large", e.message, null) }
            } catch (e: Throwable) {
                main.post {
                    pending.error("pick_failed", e.message ?: e.toString(), null)
                }
            }
        }
        return true
    }

    /**
     * The documents an `ACTION_OPEN_DOCUMENT` result carries. A multi-select
     * arrives in `clipData`; a single pick — including one made in a picker
     * that was *asked* for multiple — arrives in `data`, so both are read.
     */
    private fun pickedUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val clip = data.clipData
        if (clip != null) {
            val uris = ArrayList<Uri>(clip.itemCount)
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { uris.add(it) }
            }
            if (uris.isNotEmpty()) return uris
        }
        return listOfNotNull(data.data)
    }

    /**
     * Reads the picked document straight into memory as UTF-8 text — no
     * app-cache staging, unlike [stageForUpload], since the caller (private
     * key import) wants the content in a text field and nothing left behind
     * on disk. Refuses anything over [maxBytes], checking the size column
     * first when the provider reports one and, either way, aborting the read
     * itself the moment the cap is crossed — a provider that lies about (or
     * omits) [OpenableColumns.SIZE] cannot be used to smuggle an oversized
     * read past this.
     */
    private fun readFileContent(uri: Uri, maxBytes: Long): Map<String, Any?> {
        val resolver = activity.contentResolver
        var name = "key"
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    name = cursor.getString(nameIndex)
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    val reportedSize = cursor.getLong(sizeIndex)
                    if (reportedSize > maxBytes) {
                        throw FileTooLargeException(
                            "\"$name\" is $reportedSize bytes, over the " +
                                "$maxBytes byte limit for a key file.",
                        )
                    }
                }
            }
        }

        val buffer = java.io.ByteArrayOutputStream()
        resolver.openInputStream(uri)?.use { input ->
            val chunk = ByteArray(8 * 1024)
            var total = 0L
            while (true) {
                val read = input.read(chunk)
                if (read == -1) break
                total += read
                if (total > maxBytes) {
                    throw FileTooLargeException(
                        "\"$name\" is over the $maxBytes byte limit for a key file.",
                    )
                }
                buffer.write(chunk, 0, read)
            }
        } ?: throw IllegalStateException("Could not read the selected file.")

        return mapOf(
            "name" to name,
            "content" to String(buffer.toByteArray(), Charsets.UTF_8),
        )
    }

    /**
     * Copies the picked document into app-private cache so Dart can stream it
     * with plain file I/O. A SAF `content://` URI is not a path and its
     * permission grant does not survive the process, so staging is the only
     * honest option.
     */
    private fun stageForUpload(uri: Uri): Map<String, Any?> =
        stageOne(uri, File(newBatchDir(), "0"))

    /**
     * Stages a whole multi-select or share into one batch directory.
     *
     * A document that will not open costs itself and nothing else: a share of
     * twelve photos where one provider has already gone away should upload
     * the other eleven rather than fail as a unit.
     */
    private fun stageBatch(uris: List<Uri>): Map<String, Any?> {
        val batch = newBatchDir()
        val files = ArrayList<Map<String, Any?>>(uris.size)
        for ((index, uri) in uris.withIndex()) {
            // One subdirectory per file, so two documents that genuinely share
            // a display name ("photo.jpg" from two folders) keep both their
            // real names — the remote-collision prompt is the right place for
            // that clash to surface, not a silent rename during staging.
            val staged = runCatching { stageOne(uri, File(batch, index.toString())) }
            staged.getOrNull()?.let { files.add(it) }
        }
        if (files.isEmpty() && uris.isNotEmpty()) {
            throw IllegalStateException("None of the selected files could be read.")
        }
        return mapOf("files" to files)
    }

    private fun stageOne(uri: Uri, directory: File): Map<String, Any?> {
        val resolver = activity.contentResolver
        var name = "upload"
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
        }
        name = stagedFileName(name)

        if (!directory.exists()) directory.mkdirs()
        val target = File(directory, name)
        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(target).use { output ->
                input.copyTo(output, 64 * 1024)
            }
        } ?: throw IllegalStateException("Could not read the selected file.")

        return mapOf(
            "path" to target.absolutePath,
            "name" to name,
            "size" to target.length(),
        )
    }

    /**
     * A display name from another app's provider is not a file name: it can
     * carry separators, or be `..`. Reduce it to a single safe segment before
     * it becomes a path in our cache — and, later, a name on the user's
     * server.
     */
    private fun stagedFileName(raw: String): String {
        val segment = raw.substringAfterLast('/').substringAfterLast('\\')
        var cleaned = segment
            .map { c -> if (c.isISOControl() || c in "\\/:*?\"<>|") '_' else c }
            .joinToString("")
            .trim()
            .trimStart('.')
        if (cleaned.isEmpty()) cleaned = "upload"
        if (cleaned.length > 180) cleaned = cleaned.substring(0, 180)
        return cleaned
    }

    /**
     * A fresh directory for one pick or share, and a sweep of the ones that
     * have aged out.
     *
     * Batch directories rather than the old "clear everything each time":
     * clearing wholesale would delete the file an upload queued a minute ago
     * was still streaming. Age is the only safe signal here — the platform
     * side has no view of the queue.
     */
    private fun newBatchDir(): File {
        val root = File(activity.cacheDir, "uploads")
        if (!root.exists()) root.mkdirs()
        val cutoff = System.currentTimeMillis() - STAGING_TTL_MS
        root.listFiles()?.forEach { entry ->
            if (entry.lastModified() < cutoff) runCatching { entry.deleteRecursively() }
        }
        val batch = File(root, "b${System.currentTimeMillis()}-${nextId.getAndIncrement()}")
        batch.mkdirs()
        return batch
    }
}
