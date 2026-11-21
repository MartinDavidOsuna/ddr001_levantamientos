package com.aquafim.ddr001levantamientos

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Dedicated diagnostic build only. No automatic Flutter plugin registration. */
class RecoveryActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var exportFile: File? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        // Deliberately do not call super: no GPS, camera, session or network plugins.
        MethodChannel(engine.dartExecutor.binaryMessenger, "ddr/cabinet_recovery").setMethodCallHandler { call, result ->
            when (call.method) {
                "exclusiveRoots" -> {
                    val processes = (getSystemService(ACTIVITY_SERVICE) as ActivityManager).runningAppProcesses
                    val own = processes?.filter { it.uid == Process.myUid() }
                    if (own == null || own.size != 1 || own.single().pid != Process.myPid()) {
                        result.error("WRITERS", "No se puede garantizar proceso exclusivo.", null)
                    } else {
                        result.success(mapOf("root" to File(applicationInfo.dataDir).canonicalPath,
                            "cache" to cacheDir.canonicalPath, "exclusive" to true))
                    }
                }
                "save" -> {
                    val name = call.argument<String>("path")
                    val file = name?.let { File(it).canonicalFile }
                    val base = File(cacheDir, "cabinet_recovery").canonicalPath + File.separator
                    if (pending != null || file == null || !file.path.startsWith(base) ||
                        !file.isFile || file.name !in listOf("backup.ddr.jsonl", "inventory.json")) {
                        result.error("PATH", "Exportación no disponible.", null)
                    } else {
                        pending = result
                        exportFile = file
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, file.name)
                            // Local document providers only. No automatic cloud upload.
                            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                        }
                        try { startActivityForResult(intent, 7301) }
                        catch (_: Exception) {
                            pending = null; exportFile = null
                            result.error("DESTINATION", "No se pudo abrir un destino local.", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != 7301) { super.onActivityResult(requestCode, resultCode, data); return }
        val result = pending ?: return
        val file = exportFile
        pending = null; exportFile = null
        if (resultCode != Activity.RESULT_OK || data?.data == null || file == null) {
            result.success(false); return
        }
        try {
            contentResolver.openOutputStream(data.data!!, "wt").use { output ->
                requireNotNull(output)
                file.inputStream().use { it.copyTo(output) }
                output.flush()
            }
            // Verify the selected destination, not only the private staging copy.
            val hash = java.security.MessageDigest.getInstance("SHA-256")
            val expected = file.inputStream().use { input ->
                val bytes = ByteArray(65536)
                var count = input.read(bytes)
                while (count != -1) { hash.update(bytes, 0, count); count = input.read(bytes) }
                hash.digest()
            }
            val actual = contentResolver.openInputStream(data.data!!).use { input ->
                requireNotNull(input)
                val bytes = ByteArray(65536)
                var count = input.read(bytes)
                while (count != -1) { hash.update(bytes, 0, count); count = input.read(bytes) }
                hash.digest()
            }
            check(expected.contentEquals(actual))
            result.success(true)
        } catch (_: Exception) {
            result.error("COPY", "Destino incompleto o no verificable; copia privada conservada.", null)
        }
    }
}
