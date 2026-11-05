package dev.foxyz.media_kit_bench

import android.annotation.SuppressLint
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.renderer.FlutterRenderer
import java.util.WeakHashMap

class MainActivity : FlutterActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val hooked = WeakHashMap<ImageReader, Boolean>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 31) handler.post(::hookReaders)
    }

    // Bench-only probe: every image Flutter's ImageReaderSurfaceProducer acquires is logged as
    // "bufprobe <reader> <arrival uptime ns> <image timestamp ns> <HardwareBuffer id>", then handed to
    // Flutter exactly as its own listener does.
    @SuppressLint("NewApi")
    private fun hookReaders() {
        try {
            val renderer = flutterEngine?.renderer
            if (renderer != null) {
                val producers = FlutterRenderer::class.java.getDeclaredField("imageReaderProducers")
                    .apply { isAccessible = true }.get(renderer) as Collection<*>
                for (producer in producers.toList()) {
                    if (producer == null) continue
                    val cls = producer.javaClass
                    if (cls.simpleName != "ImageReaderSurfaceProducer") continue
                    val readers = cls.getDeclaredField("perImageReaders").apply { isAccessible = true }
                        .get(producer) as Map<*, *>
                    val released = cls.getDeclaredField("released").apply { isAccessible = true }
                    val onImage = cls.getDeclaredMethod("onImage", ImageReader::class.java, Image::class.java)
                        .apply { isAccessible = true }
                    for (key in readers.keys.toList()) {
                        val reader = key as? ImageReader ?: continue
                        if (hooked.containsKey(reader)) continue
                        hooked[reader] = true
                        val name = Integer.toHexString(System.identityHashCode(reader))
                        Log.i("bufprobe", "hook $name ${reader.width}x${reader.height} max=${reader.maxImages}")
                        reader.setOnImageAvailableListener({ r ->
                            val image = try {
                                r.acquireLatestImage()
                            } catch (e: IllegalStateException) {
                                null
                            } ?: return@setOnImageAvailableListener
                            val per = readers[r]
                            val closed = per != null && per.javaClass.getDeclaredField("closed")
                                .apply { isAccessible = true }.getBoolean(per)
                            if (per == null || closed || released.getBoolean(producer)) {
                                image.close()
                                return@setOnImageAvailableListener
                            }
                            val id = image.hardwareBuffer?.let { hb -> hb.id.also { hb.close() } } ?: -1L
                            Log.i("bufprobe", "f $name ${System.nanoTime()} ${image.timestamp} $id")
                            onImage.invoke(producer, r, image)
                        }, handler)
                    }
                }
            }
        } catch (e: Throwable) {
            Log.w("bufprobe", "hook failed: $e")
        }
        handler.postDelayed(::hookReaders, 16)
    }
}
