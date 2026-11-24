package io.github.ccch1mneyyy.dsh_app.web

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * 发图前压缩（简报 #37）：长边 1568、JPEG 质量 80、目标 1MB 以内。
 *
 * 网页模式下图片由 WebView 自己从 content URI 读，字节不经过 Dart，所以压缩只能
 * 在这里做：系统选择器给出临时 URI，我们缩好写成缓存文件，再把 FileProvider URI
 * 交给 WebView。GIF（会丢动画）、SVG 和读不出的图原样返回，不替网页做决定。
 */
internal object UploadImage {
    private const val MAX_SIDE = 1568
    private const val QUALITY = 80
    private const val MAX_BYTES = 1 shl 20
    private const val FOLDER = "artifacts/web-upload"
    private const val TTL_MS = 6 * 60 * 60 * 1000L

    /** A stand-in URI for one picked file, or the original when nothing is worth doing. */
    fun standIn(context: Context, uri: Uri): Uri {
        val mime = runCatching { context.contentResolver.getType(uri) }.getOrNull() ?: return uri
        if (!mime.startsWith("image/") || mime == "image/gif" || mime == "image/svg+xml") return uri
        val bitmap = decode(context, uri) ?: return uri
        val scaled = fit(bitmap)
        val bytes = encode(scaled) ?: return uri
        val folder = File(context.cacheDir, FOLDER).apply { mkdirs() }
        prune(folder)
        val file = File(folder, "upload-${System.currentTimeMillis()}-${bytes.size}.jpg")
        return try {
            file.writeBytes(bytes)
            FileProvider.getUriForFile(context, context.packageName + ".files", file)
        } catch (_: Exception) {
            uri
        }
    }

    private fun decode(context: Context, uri: Uri): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            null
        } else {
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2
            val options = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        }
    } catch (_: Exception) {
        null
    }

    private fun fit(bitmap: Bitmap): Bitmap {
        val long = maxOf(bitmap.width, bitmap.height)
        if (long <= MAX_SIDE) return bitmap
        val ratio = MAX_SIDE.toFloat() / long
        val width = (bitmap.width * ratio).toInt().coerceAtLeast(1)
        val height = (bitmap.height * ratio).toInt().coerceAtLeast(1)
        val target = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        // 透明区会被 JPEG 压成黑块，先铺白底。
        Canvas(target).apply {
            drawColor(Color.WHITE)
            drawBitmap(bitmap, null, Rect(0, 0, width, height), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        return target
    }

    private fun encode(bitmap: Bitmap): ByteArray? {
        for (quality in intArrayOf(QUALITY, 70, 60, 50, 40)) {
            val out = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) continue
            if (out.size() <= MAX_BYTES) return out.toByteArray()
        }
        return null
    }

    /** Chromium reads the file lazily; keep a while and drop the rest. */
    private fun prune(folder: File) {
        val now = System.currentTimeMillis()
        folder.listFiles()?.forEach { if (now - it.lastModified() > TTL_MS) it.delete() }
    }
}
