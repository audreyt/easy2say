package org.audreyt.v2s.android.spike

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer


enum class SpikeMode {
    CAPTION,
    CONVERSATION,
}

data class SpikeConfig(
    val mode: SpikeMode,
    val primaryLanguageTag: String,
    val secondaryLanguageTag: String? = null,
) {
    val requestedLanguageTags: List<String>
        get() = buildList {
            add(primaryLanguageTag)
            if (mode == SpikeMode.CONVERSATION) {
                secondaryLanguageTag?.let(::add)
            }
        }.distinct()
}

data class SpokenResult(
    val text: String,
    val confidence: Float?,
    val detectedLanguageTag: String?,
    val lane: ConversationLane,
)

data class LanguageDetection(
    val languageTag: String?,
    val confidenceLabel: String,
    val switchResultLabel: String,
    val alternatives: List<String>,
    val acceptedForRouting: Boolean,
)

interface SpeechSpikeEvents {
    fun onStatus(message: String, active: Boolean)
    fun onCapabilityReport(report: String)
    fun onPartial(result: SpokenResult)
    fun onFinal(result: SpokenResult)
    fun onLanguageDetection(detection: LanguageDetection)
}

/**
 * API-34 platform probe. It intentionally has no network recognizer fallback: if the
 * device cannot prove an installed on-device model, the session stops.
 */
class SpeechSpikeController(
    private val context: Context,
    private val events: SpeechSpikeEvents,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    private var recognizer: SpeechRecognizer? = null
    private var config: SpikeConfig? = null
    private var recognitionIntent: Intent? = null
    private var generation = 0
    private var active = false
    private var listening = false
    private var restartRunnable: Runnable? = null
    private var routedLanguageTag: String? = null
    private var downloadAttempts = mutableSetOf<String>()
    private var lastFinalSignature: String? = null
    private var lastFinalTimeMillis = 0L

    fun start(newConfig: SpikeConfig) {
        require(Looper.myLooper() == Looper.getMainLooper()) {
            "SpeechRecognizer must be controlled from the main thread"
        }

        stopInternal(notify = false)
        generation += 1
        val token = generation
        config = newConfig
        recognitionIntent = buildRecognitionIntent(newConfig)
        downloadAttempts = mutableSetOf()
        active = true
        events.onStatus("Checking the device's on-device recognizer…", active = true)

        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            fail(token, "Microphone permission is required.")
            return
        }

        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            fail(token, "No on-device SpeechRecognizer is installed. Network fallback is disabled.")
            return
        }

        val created = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (error: RuntimeException) {
            fail(token, "Could not create the on-device recognizer: ${error.message ?: error.javaClass.simpleName}")
            return
        }

        recognizer = created
        created.setRecognitionListener(listenerFor(token))
        checkSupport(token)
    }

    fun stop() {
        generation += 1
        stopInternal(notify = true)
    }

    fun close() {
        generation += 1
        stopInternal(notify = false)
    }

    private fun checkSupport(token: Int) {
        val currentRecognizer = recognizer ?: return
        val intent = recognitionIntent ?: return
        events.onStatus("Checking installed speech models…", active = true)

        try {
            currentRecognizer.checkRecognitionSupport(
                intent,
                context.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                        if (!isCurrent(token)) return
                        handleSupportResult(token, recognitionSupport)
                    }

                    override fun onError(error: Int) {
                        fail(
                            token,
                            "The on-device recognizer cannot prove this configuration " +
                                "(${errorName(error)}).",
                        )
                    }
                },
            )
        } catch (error: RuntimeException) {
            fail(token, "Capability check failed: ${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun handleSupportResult(token: Int, support: RecognitionSupport) {
        val requested = config?.requestedLanguageTags.orEmpty()
        val installed = support.installedOnDeviceLanguages
        val pending = support.pendingOnDeviceLanguages
        val supported = support.supportedOnDeviceLanguages
        val online = support.onlineLanguages

        events.onCapabilityReport(
            buildString {
                appendLine("ON-DEVICE RECOGNIZER: available")
                appendLine("REQUESTED: ${requested.joinToString()}")
                appendLine("INSTALLED: ${installed.sorted().ifEmpty { listOf("none") }.joinToString()}")
                appendLine("SUPPORTED: ${supported.sorted().ifEmpty { listOf("none reported") }.joinToString()}")
                appendLine("PENDING: ${pending.sorted().ifEmpty { listOf("none") }.joinToString()}")
                append("ONLINE (ignored): ${online.sorted().ifEmpty { listOf("none reported") }.joinToString()}")
            },
        )

        val missing = requested.filterNot { LanguagePairRouter.covers(it, installed) }
        if (missing.isEmpty()) {
            beginListening(token)
            return
        }

        val requestedAndPending = missing.filter { LanguagePairRouter.covers(it, pending) }
        if (requestedAndPending.isNotEmpty()) {
            finishWithoutListening(
                token,
                "${requestedAndPending.joinToString()} model download is still pending. " +
                    "Tap Start after Android finishes it.",
            )
            return
        }

        val downloadable = supported
        val unsupported = missing.filterNot { LanguagePairRouter.covers(it, downloadable) }
        if (unsupported.isNotEmpty()) {
            fail(
                token,
                "No installed or downloadable on-device model was reported for " +
                    unsupported.joinToString() + ".",
            )
            return
        }

        downloadLanguages(token, missing, index = 0)
    }

    private fun downloadLanguages(token: Int, missing: List<String>, index: Int) {
        if (!isCurrent(token)) return
        if (index >= missing.size) {
            checkSupport(token)
            return
        }

        val languageTag = missing[index]
        if (!downloadAttempts.add(languageTag)) {
            fail(token, "The $languageTag model download completed but the model is still unavailable.")
            return
        }

        val currentRecognizer = recognizer ?: return
        events.onStatus("Downloading the on-device $languageTag speech model…", active = true)

        try {
            currentRecognizer.triggerModelDownload(
                buildRecognitionIntent(
                    SpikeConfig(
                        mode = SpikeMode.CAPTION,
                        primaryLanguageTag = languageTag,
                    ),
                ),
                context.mainExecutor,
                object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) {
                        if (!isCurrent(token)) return
                        events.onStatus(
                            "Downloading $languageTag speech model: $completedPercent%",
                            active = true,
                        )
                    }

                    override fun onSuccess() {
                        if (!isCurrent(token)) return
                        downloadLanguages(token, missing, index + 1)
                    }

                    override fun onScheduled() {
                        finishWithoutListening(
                            token,
                            "$languageTag model download was scheduled by Android. " +
                                "Tap Start after the system finishes it.",
                        )
                    }

                    override fun onError(error: Int) {
                        fail(token, "$languageTag model download failed (${errorName(error)}).")
                    }
                },
            )
        } catch (error: RuntimeException) {
            fail(token, "Could not request the $languageTag model: ${error.message ?: error.javaClass.simpleName}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun beginListening(token: Int) {
        if (!isCurrent(token)) return
        val currentRecognizer = recognizer ?: return
        val intent = recognitionIntent ?: return

        routedLanguageTag = null
        listening = true
        events.onStatus("Starting an on-device speech segment…", active = true)
        try {
            currentRecognizer.startListening(intent)
        } catch (error: RuntimeException) {
            listening = false
            fail(token, "Could not start speech recognition: ${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun listenerFor(token: Int): RecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle) {
            if (!isCurrent(token)) return
            events.onStatus("Listening on device", active = true)
        }

        override fun onBeginningOfSpeech() {
            if (!isCurrent(token)) return
            routedLanguageTag = null
            events.onStatus("Hearing speech…", active = true)
        }

        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray) = Unit

        override fun onEndOfSpeech() {
            if (!isCurrent(token)) return
            events.onStatus("Finalizing this segment…", active = true)
        }

        override fun onError(error: Int) {
            if (!isCurrent(token)) return
            listening = false
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                SpeechRecognizer.ERROR_CLIENT,
                -> scheduleRestart(token, delayMillis = 250L, reason = "Listening for the next segment…")

                SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                    scheduleRestart(token, delayMillis = 750L, reason = "Recognizer busy; retrying…")

                SpeechRecognizer.ERROR_NETWORK,
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                SpeechRecognizer.ERROR_SERVER,
                SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
                -> fail(
                    token,
                    "The on-device recognizer returned ${errorName(error)}. " +
                        "Network/server fallback is forbidden.",
                )

                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE,
                -> fail(token, "Speech language unavailable (${errorName(error)}).")

                else -> fail(token, "Speech recognition stopped (${errorName(error)}).")
            }
        }

        override fun onResults(results: Bundle) {
            if (!isCurrent(token)) return
            listening = false
            commitResult(results)
            scheduleRestart(token, delayMillis = 180L, reason = "Listening for the next segment…")
        }

        override fun onPartialResults(partialResults: Bundle) {
            if (!isCurrent(token)) return
            val result = resultFrom(partialResults) ?: return
            events.onPartial(result)
        }

        override fun onSegmentResults(segmentResults: Bundle) {
            if (!isCurrent(token)) return
            commitResult(segmentResults)
        }

        override fun onEndOfSegmentedSession() {
            if (!isCurrent(token)) return
            listening = false
            scheduleRestart(token, delayMillis = 180L, reason = "Listening for the next segment…")
        }

        override fun onLanguageDetection(results: Bundle) {
            if (!isCurrent(token)) return

            val languageTag = results.getString(SpeechRecognizer.DETECTED_LANGUAGE)
            val confidence = results.getInt(
                SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL,
                SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_UNKNOWN,
            )
            val switchResult = results.getInt(
                SpeechRecognizer.LANGUAGE_SWITCH_RESULT,
                SpeechRecognizer.LANGUAGE_SWITCH_RESULT_NOT_ATTEMPTED,
            )
            val accepted = confidence == SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_CONFIDENT ||
                confidence == SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_HIGHLY_CONFIDENT

            routedLanguageTag = languageTag.takeIf { accepted }
            events.onLanguageDetection(
                LanguageDetection(
                    languageTag = languageTag,
                    confidenceLabel = confidenceLabel(confidence),
                    switchResultLabel = switchResultLabel(switchResult),
                    alternatives = results.getStringArrayList(SpeechRecognizer.TOP_LOCALE_ALTERNATIVES)
                        .orEmpty(),
                    acceptedForRouting = accepted,
                ),
            )
        }

        override fun onEvent(eventType: Int, params: Bundle) = Unit
    }

    private fun commitResult(results: Bundle) {
        val result = resultFrom(results) ?: return
        val signature = "${result.text}\u0000${result.detectedLanguageTag.orEmpty()}"
        val now = SystemClock.elapsedRealtime()
        if (signature == lastFinalSignature && now - lastFinalTimeMillis < 1_500L) return

        lastFinalSignature = signature
        lastFinalTimeMillis = now
        events.onFinal(result)
    }

    private fun resultFrom(results: Bundle): SpokenResult? {
        val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: return null
        val confidence = results.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
            ?.firstOrNull()
            ?.takeIf { it >= 0f }
        val currentConfig = config ?: return null
        val languageTag = routedLanguageTag
        val lane = if (currentConfig.mode == SpikeMode.CONVERSATION) {
            LanguagePairRouter.route(
                detectedLanguageTag = languageTag,
                primaryLanguageTag = currentConfig.primaryLanguageTag,
                secondaryLanguageTag = currentConfig.secondaryLanguageTag.orEmpty(),
            )
        } else {
            ConversationLane.PRIMARY
        }

        return SpokenResult(
            text = text,
            confidence = confidence,
            detectedLanguageTag = languageTag,
            lane = lane,
        )
    }

    private fun scheduleRestart(token: Int, delayMillis: Long, reason: String) {
        if (!isCurrent(token)) return
        restartRunnable?.let(mainHandler::removeCallbacks)
        events.onStatus(reason, active = true)
        val restart = Runnable {
            if (isCurrent(token) && !listening) beginListening(token)
        }
        restartRunnable = restart
        mainHandler.postDelayed(restart, delayMillis)
    }

    private fun buildRecognitionIntent(currentConfig: SpikeConfig): Intent {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, currentConfig.primaryLanguageTag)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_CONFIDENCE, true)
            putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_TIMING, true)
        }

        if (currentConfig.mode == SpikeMode.CONVERSATION) {
            val languages = ArrayList(currentConfig.requestedLanguageTags)
            intent.putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
            intent.putStringArrayListExtra(
                RecognizerIntent.EXTRA_LANGUAGE_DETECTION_ALLOWED_LANGUAGES,
                languages,
            )
            intent.putExtra(
                RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH,
                RecognizerIntent.LANGUAGE_SWITCH_QUICK_RESPONSE,
            )
            intent.putStringArrayListExtra(
                RecognizerIntent.EXTRA_LANGUAGE_SWITCH_ALLOWED_LANGUAGES,
                languages,
            )
        }

        return intent
    }

    private fun fail(token: Int, message: String) {
        if (!isCurrent(token)) return
        generation += 1
        stopInternal(notify = false)
        events.onStatus(message, active = false)
    }

    private fun finishWithoutListening(token: Int, message: String) {
        if (!isCurrent(token)) return
        generation += 1
        stopInternal(notify = false)
        events.onStatus(message, active = false)
    }

    private fun stopInternal(notify: Boolean) {
        active = false
        listening = false
        restartRunnable?.let(mainHandler::removeCallbacks)
        restartRunnable = null
        recognizer?.let { current ->
            try {
                current.cancel()
            } catch (_: RuntimeException) {
                // Destruction below is the definitive cleanup.
            }
            current.destroy()
        }
        recognizer = null
        recognitionIntent = null
        routedLanguageTag = null
        if (notify) events.onStatus("Stopped", active = false)
    }

    private fun isCurrent(token: Int): Boolean = active && generation == token

    private fun confidenceLabel(value: Int): String = when (value) {
        SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_NOT_CONFIDENT -> "not confident"
        SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_CONFIDENT -> "confident"
        SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_HIGHLY_CONFIDENT -> "highly confident"
        else -> "unknown"
    }

    private fun switchResultLabel(value: Int): String = when (value) {
        SpeechRecognizer.LANGUAGE_SWITCH_RESULT_SUCCEEDED -> "switched"
        SpeechRecognizer.LANGUAGE_SWITCH_RESULT_FAILED -> "switch failed"
        SpeechRecognizer.LANGUAGE_SWITCH_RESULT_SKIPPED_NO_MODEL -> "missing model"
        SpeechRecognizer.LANGUAGE_SWITCH_RESULT_NOT_ATTEMPTED -> "not attempted"
        else -> "unknown result $value"
    }

    private fun errorName(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "audio error"
        SpeechRecognizer.ERROR_CLIENT -> "client restart"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "insufficient permission"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "language not supported"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "language model unavailable"
        SpeechRecognizer.ERROR_NETWORK -> "network error"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network timeout"
        SpeechRecognizer.ERROR_NO_MATCH -> "no match"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "recognizer busy"
        SpeechRecognizer.ERROR_SERVER -> "server error"
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "server disconnected"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech timeout"
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "too many requests"
        else -> "error $error"
    }
}
