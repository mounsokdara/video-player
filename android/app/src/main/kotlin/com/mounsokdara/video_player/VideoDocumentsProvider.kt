package com.mounsokdara.video_player

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * Surfaces this app in the system file picker's "Open from" sidebar.
 * https://developer.android.com/guide/topics/providers/create-document-provider
 */
class VideoDocumentsProvider : DocumentsProvider() {
    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<String>?): Cursor {
        val result = MatrixCursor(projection ?: ROOT_COLUMNS)
        result.newRow()
            .add(DocumentsContract.Root.COLUMN_ROOT_ID, ROOT_ID)
            .add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, DOC_ROOT)
            .add(DocumentsContract.Root.COLUMN_TITLE, "Video Player")
            .add(DocumentsContract.Root.COLUMN_SUMMARY, "Videos on this device")
            .add(DocumentsContract.Root.COLUMN_ICON, R.mipmap.ic_launcher)
            .add(DocumentsContract.Root.COLUMN_MIME_TYPES, "video/*")
            .add(
                DocumentsContract.Root.COLUMN_FLAGS,
                DocumentsContract.Root.FLAG_LOCAL_ONLY or
                    DocumentsContract.Root.FLAG_SUPPORTS_RECENTS
            )
        return result
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        val result = MatrixCursor(projection ?: DOC_COLUMNS)
        if (documentId == DOC_ROOT) {
            addRootDoc(result)
        } else {
            addVideo(result, documentId) ?: throw FileNotFoundException(documentId)
        }
        return result
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?
    ): Cursor {
        val result = MatrixCursor(projection ?: DOC_COLUMNS)
        if (parentDocumentId != DOC_ROOT) return result
        for (row in loadVideos(limit = 400)) addVideoRow(result, row)
        return result
    }

    override fun queryRecentDocuments(rootId: String, projection: Array<String>?): Cursor {
        val result = MatrixCursor(projection ?: DOC_COLUMNS)
        for (row in loadVideos(limit = 64)) addVideoRow(result, row)
        return result
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val file = resolveFile(documentId) ?: throw FileNotFoundException(documentId)
        val parsed = ParcelFileDescriptor.parseMode(if (mode.contains("w")) "r" else mode)
        return ParcelFileDescriptor.open(file, parsed)
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        return parentDocumentId == DOC_ROOT && documentId.startsWith("v:")
    }

    private fun addRootDoc(result: MatrixCursor) {
        result.newRow()
            .add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DOC_ROOT)
            .add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, "Video Player")
            .add(DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.MIME_TYPE_DIR)
            .add(DocumentsContract.Document.COLUMN_FLAGS, 0)
            .add(DocumentsContract.Document.COLUMN_SIZE, 0L)
            .add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, System.currentTimeMillis())
    }

    private fun addVideo(result: MatrixCursor, documentId: String): Boolean? {
        val row = loadVideos(limit = 800).firstOrNull { it.id == documentId } ?: return null
        addVideoRow(result, row)
        return true
    }

    private fun addVideoRow(result: MatrixCursor, row: VideoRow) {
        result.newRow()
            .add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, row.id)
            .add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, row.name)
            .add(DocumentsContract.Document.COLUMN_MIME_TYPE, row.mime)
            .add(DocumentsContract.Document.COLUMN_FLAGS, 0)
            .add(DocumentsContract.Document.COLUMN_SIZE, row.size)
            .add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, row.modified)
    }

    private data class VideoRow(
        val id: String,
        val path: String,
        val name: String,
        val mime: String,
        val size: Long,
        val modified: Long
    )

    private fun resolveFile(documentId: String): File? {
        if (!documentId.startsWith("v:")) return null
        val path = documentId.removePrefix("v:")
        val f = File(path)
        return if (f.exists()) f else null
    }

    private fun loadVideos(limit: Int): List<VideoRow> {
        val out = ArrayList<VideoRow>()
        val cr = context?.contentResolver ?: return out
        val uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.MIME_TYPE,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_MODIFIED
        )
        return try {
            cr.query(uri, projection, null, null, "${MediaStore.Video.Media.DATE_MODIFIED} DESC")?.use { c ->
                val iPath = c.getColumnIndex(MediaStore.Video.Media.DATA)
                val iName = c.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
                val iMime = c.getColumnIndex(MediaStore.Video.Media.MIME_TYPE)
                val iSize = c.getColumnIndex(MediaStore.Video.Media.SIZE)
                val iMod = c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED)
                while (c.moveToNext() && out.size < limit) {
                    if (iPath < 0) continue
                    val path = c.getString(iPath) ?: continue
                    if (path.isBlank() || !File(path).exists()) continue
                    val name = if (iName >= 0) c.getString(iName) ?: File(path).name else File(path).name
                    val mime = if (iMime >= 0) c.getString(iMime) else null
                    val size = if (iSize >= 0) c.getLong(iSize) else File(path).length()
                    val modified = if (iMod >= 0) c.getLong(iMod) * 1000L else File(path).lastModified()
                    out.add(
                        VideoRow(
                            id = "v:$path",
                            path = path,
                            name = name,
                            mime = mime ?: mimeOf(path),
                            size = size,
                            modified = modified
                        )
                    )
                }
            }
            out
        } catch (_: Exception) {
            out
        }
    }

    private fun mimeOf(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "video/*"
    }

    companion object {
        private const val ROOT_ID = "videos"
        private const val DOC_ROOT = "root"
        private val ROOT_COLUMNS = arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.COLUMN_ICON,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_SUMMARY,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_MIME_TYPES
        )
        private val DOC_COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
    }
}
