package com.pocketstrike.pocketstrike

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import java.io.File
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * Runs Local Dream's image engine (github.com/xororz/local-dream by xororz,
 * CC BY-NC 4.0) inside PocketStrike, the same way Local Dream's own
 * BackendService does: the native engine `libstable_diffusion_core.so` from
 * nativeLibraryDir, Qualcomm's NPU runtime copied from assets/qnnlibs, and a
 * model folder that Local Dream downloaded. The engine then serves
 * http://127.0.0.1:[PORT] (this phone only) with the same /health and
 * /generate API as in Local Dream.
 *
 * Models are read from Download/LocalDream/models — where Local Dream puts
 * them after "Model storage → Downloads" in its settings — so both apps share
 * one copy. Reading there needs "All files access" for PocketStrike.
 */
object ImageEngine {
    private const val TAG = "ImageEngine"

    /** Not Local Dream's 8081, so both can run without fighting over the port. */
    const val PORT = 8082

    private const val EXECUTABLE = "libstable_diffusion_core.so"
    private const val RUNTIME_DIR = "qnn_runtime"

    /** Local Dream NPU models PocketStrike knows how to start, by folder name. */
    private data class Known(val name: String, val type: String, val size: Int)

    private val KNOWN = mapOf(
        "illustrious_v16_dmd2" to Known("Illustrious v16 DMD2", "sdxl", 1024),
        "illustrious_v16" to Known("Illustrious v16", "sdxl", 1024),
        "cyber_realistic_v10_dmd2" to Known("CyberRealistic v10 DMD2", "sdxl", 1024),
        "cyber_realistic_v10" to Known("CyberRealistic v10", "sdxl", 1024),
    )

    @Volatile private var process: Process? = null
    @Volatile private var runningModel: String? = null
    @Volatile private var exitCode: Int? = null
    private val log = ArrayDeque<String>()

    private val modelsDir: File
        get() = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "LocalDream/models",
        )

    fun hasFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true

    fun openFilesAccessSettings(context: Context) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            )
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        }
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun isBundled(context: Context): Boolean =
        File(context.applicationInfo.nativeLibraryDir, EXECUTABLE).exists()

    /** The models PocketStrike can run, with the defaults from each model's config.json. */
    fun listModels(): List<Map<String, Any?>> {
        val dirs = modelsDir.listFiles()?.filter { it.isDirectory } ?: return emptyList()
        return dirs.sortedBy { it.name }.mapNotNull { dir ->
            val known = KNOWN[dir.name] ?: return@mapNotNull null
            if (dir.listFiles().isNullOrEmpty()) return@mapNotNull null
            val cfg = runCatching { JSONObject(File(dir, "config.json").readText()) }.getOrNull()
            mapOf(
                "id" to dir.name,
                "name" to known.name,
                "size" to known.size,
                "steps" to cfg?.takeIf { it.has("default_steps") }?.optDouble("default_steps"),
                "cfg" to cfg?.takeIf { it.has("default_cfg") }?.optDouble("default_cfg"),
                "scheduler" to cfg?.optString("default_scheduler")?.takeIf { it.isNotEmpty() },
                "negative" to cfg?.optString("default_negative_prompt")?.takeIf { it.isNotEmpty() },
            )
        }
    }

    fun status(): Map<String, Any?> = mapOf(
        "running" to (process?.isAlive == true),
        "model" to runningModel,
        "exitCode" to exitCode,
        "log" to synchronized(log) { log.joinToString("\n") },
    )

    /** Starts the engine with [modelId]; returns null, or a sentence saying why not. */
    @Synchronized
    fun start(context: Context, modelId: String): String? {
        if (runningModel == modelId && process?.isAlive == true) return null
        stop()
        val known = KNOWN[modelId] ?: return "PocketStrike doesn't know how to run '$modelId'."
        if (!hasFilesAccess()) return "PocketStrike needs All files access to read Download/LocalDream."
        val modelDir = File(modelsDir, modelId)
        if (!modelDir.isDirectory) return "Model folder not found: ${modelDir.path}"
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val executable = File(nativeDir, EXECUTABLE)
        if (!executable.exists()) return "This PocketStrike build doesn't include the image engine."
        val runtime = prepareRuntime(context) ?: return "Couldn't prepare the NPU runtime."
        killStray()

        val command = mutableListOf(
            executable.absolutePath,
            "--type", known.type,
            "--model_dir", modelDir.absolutePath,
            "--port", PORT.toString(),
            "--lib_dir", runtime.absolutePath,
        )
        // Local Dream's defaults: SDXL loads and releases stages to save RAM.
        if (known.type == "sdxl") command += "--lowram"
        if (File(modelDir, "V_PRED").exists()) command += "--use_v_pred"

        return try {
            val builder = ProcessBuilder(command)
                .directory(File(nativeDir))
                .redirectErrorStream(true)
            builder.environment()["LD_LIBRARY_PATH"] =
                listOf(runtime.absolutePath, "/system/lib64", "/vendor/lib64", "/vendor/lib64/egl")
                    .joinToString(":")
            builder.environment()["DSP_LIBRARY_PATH"] = runtime.absolutePath
            synchronized(log) { log.clear() }
            exitCode = null
            val proc = builder.start()
            process = proc
            runningModel = modelId
            Thread({
                try {
                    proc.inputStream.bufferedReader().forEachLine { line ->
                        Log.i(TAG, line)
                        synchronized(log) {
                            log.addLast(line)
                            while (log.size > 40) log.removeFirst()
                        }
                    }
                    exitCode = proc.waitFor()
                } catch (e: Exception) {
                    Log.w(TAG, "monitor: ${e.message}")
                }
                Log.i(TAG, "engine exited: $exitCode")
            }, "image-engine-log").start()
            null
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            process = null
            runningModel = null
            "The image engine didn't start: ${e.message}"
        }
    }

    @Synchronized
    fun stop() {
        val proc = process ?: return
        proc.destroy()
        if (!runCatching { proc.waitFor(3, TimeUnit.SECONDS) }.getOrDefault(false)) proc.destroyForcibly()
        process = null
        runningModel = null
    }

    /**
     * Copies the NPU runtime from assets once per app version (Local Dream
     * does the same into its files dir). The engine dlopens these files.
     */
    private fun prepareRuntime(context: Context): File? = try {
        val dir = File(context.filesDir, RUNTIME_DIR)
        val stamp = File(dir, ".version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (!dir.exists() || runCatching { stamp.readText() }.getOrNull() != version) {
            dir.deleteRecursively()
            dir.mkdirs()
            context.assets.list("qnnlibs")?.forEach { name ->
                val target = File(dir, name)
                context.assets.open("qnnlibs/$name").use { input -> target.outputStream().use { input.copyTo(it) } }
                target.setReadable(true, true)
                target.setExecutable(true, true)
            }
            stamp.writeText(version)
        }
        dir.setReadable(true, true)
        dir.setExecutable(true, true)
        dir
    } catch (e: Exception) {
        Log.e(TAG, "prepare runtime failed", e)
        null
    }

    /** An engine left over from a previous PocketStrike process still holds the port: end it. */
    private fun killStray() {
        File("/proc").listFiles()?.forEach { p ->
            val pid = p.name.toIntOrNull() ?: return@forEach
            val cmdline = runCatching { File(p, "cmdline").readText() }.getOrNull() ?: return@forEach
            if (cmdline.contains(EXECUTABLE) && cmdline.contains("$PORT")) {
                Log.i(TAG, "ending stray engine $pid")
                android.os.Process.killProcess(pid)
            }
        }
    }
}
