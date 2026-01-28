package com.example.flutter_offline_map

import android.app.ActivityManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// MediaPipe GenAI Imports
import com.google.mediapipe.tasks.genai.llminference.LlmInference

class MainActivity : FlutterActivity() {
    private val CHANNEL = "mediapipe_gemma"
    private var llmInference: LlmInference? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // 1. 모델 초기화 요청 처리
                "initializeModel" -> {
                    val modelPath = call.argument<String>("modelPath")
                    val maxTokens = call.argument<Int>("maxTokens")
                    val topK = call.argument<Int>("topK")
                    initializeModel(modelPath, maxTokens, topK, result)
                }
                // 2. 텍스트 생성 요청 처리
                "generateText" -> {
                    val prompt = call.argument<String>("prompt") ?: ""
                    generateText(prompt, result)
                }
                // 2-1. 기기 성능 프로필 조회
                "getDeviceProfile" -> {
                    getDeviceProfile(result)
                }
                // 3. 리소스 해제
                "dispose" -> {
                    llmInference?.close()
                    llmInference = null
                    result.success(null)
                }
                else -> result.notImplemented() // 정의되지 않은 메서드 호출 시
            }
        }
    }

    // 모델 초기화 함수
    private fun initializeModel(
        modelPath: String?,
        maxTokens: Int?,
        topK: Int?,
        result: MethodChannel.Result,
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val finalModelPath = modelPath ?: "/data/local/tmp/llm/gemma-3-1b-it.task"
                val modelFile = File(finalModelPath)
                if (!modelFile.exists()) {
                    withContext(Dispatchers.Main) {
                        result.error("NOT_FOUND", "모델 파일 없음: $finalModelPath", null)
                    }
                    return@launch
                }

                val finalMaxTokens = maxTokens ?: 768
                val finalTopK = topK ?: 40

                llmInference?.close()
                llmInference = null

                val options = LlmInference.LlmInferenceOptions.builder()
                    .setModelPath(finalModelPath)
                    .setMaxTokens(finalMaxTokens)
                    .setMaxTopK(finalTopK)
                    .build()

                llmInference = LlmInference.createFromOptions(context, options)

                withContext(Dispatchers.Main) { result.success(true) }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("INIT_ERROR", e.message, null)
                }
            }
        }
    }

    private fun getDeviceProfile(result: MethodChannel.Result) {
        try {
            val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
            val memoryInfo = ActivityManager.MemoryInfo()
            activityManager.getMemoryInfo(memoryInfo)
            val totalRamMb = (memoryInfo.totalMem / (1024 * 1024)).toInt()
            val profile = hashMapOf<String, Any>(
                "cpuCores" to Runtime.getRuntime().availableProcessors(),
                "memoryClassMb" to activityManager.memoryClass,
                "largeMemoryClassMb" to activityManager.largeMemoryClass,
                "totalRamMb" to totalRamMb,
                "abis" to Build.SUPPORTED_ABIS.toList(),
            )
            result.success(profile)
        } catch (e: Exception) {
            result.error("PROFILE_ERROR", e.message, null)
        }
    }

    // 텍스트 생성 함수
    private fun generateText(prompt: String, result: MethodChannel.Result) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                if (llmInference == null) {
                    withContext(Dispatchers.Main) {
                        result.error("NOT_INIT", "모델이 초기화되지 않음", null)
                    }
                    return@launch
                }

                // Gemma 답변 생성
                val response = llmInference?.generateResponse(prompt)

                withContext(Dispatchers.Main) { result.success(response) }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("GEN_ERROR", e.message, null)
                }
            }
        }
    }
}
