package org.audreyt.v2s.android.spike

import android.app.PendingIntent
import android.content.Context
import android.os.CancellationSignal
import android.os.Looper
import android.view.translation.TranslationCapability
import android.view.translation.TranslationContext
import android.view.translation.TranslationManager
import android.view.translation.TranslationRequest
import android.view.translation.TranslationRequestValue
import android.view.translation.TranslationResponse
import android.view.translation.TranslationResponseValue
import android.view.translation.TranslationSpec
import android.view.translation.Translator
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors


data class TranslatedResult(
    val sourceText: String,
    val translatedText: String,
    val sourceLanguageTag: String,
    val targetLanguageTag: String,
    val sourceLane: ConversationLane,
    val targetLane: ConversationLane,
)

interface SystemTranslationEvents {
    fun onTranslationStatus(message: String)
    fun onTranslationCapabilityReport(report: String)
    fun onTranslationPreparationFailed(message: String)
    fun onTranslationResult(result: TranslatedResult)
    fun onTranslationFailure(sourceText: String, targetLane: ConversationLane, message: String)
}

/**
 * Adapter over Android's OEM-provided on-device TranslationService (API 31+).
 * No translation model or network client is bundled in the APK.
 */
class SystemTranslationController(
    private val context: Context,
    private val events: SystemTranslationEvents,
) {
    private val manager = context.getSystemService(TranslationManager::class.java)
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "v2s-system-translation-capabilities")
    }

    private var generation = 0
    private var closed = false
    private var directions: List<TranslationDirection> = emptyList()
    private val translators = mutableMapOf<TranslationDirection, Translator>()
    private val cancellationSignals = mutableSetOf<CancellationSignal>()

    val hasSettingsActivity: Boolean
        get() = manager?.onDeviceTranslationSettingsActivityIntent != null

    fun prepare(config: SpikeConfig, onReady: () -> Unit) {
        checkMainThread()
        stopInternal()
        generation += 1
        val token = generation
        val required = TranslationRoutePlanner.requiredDirections(config)
        directions = required

        if (required.isEmpty()) {
            failPreparation(token, "A translation target is required.")
            return
        }

        val currentManager = manager
        if (currentManager == null) {
            events.onTranslationCapabilityReport("SYSTEM TRANSLATION SERVICE: unavailable")
            failPreparation(token, "This device does not provide Android's on-device TranslationService.")
            return
        }

        events.onTranslationStatus("Checking Android's on-device translation capabilities…")
        worker.execute {
            val result = try {
                Result.success(
                    currentManager.getOnDeviceTranslationCapabilities(
                        TranslationSpec.DATA_FORMAT_TEXT,
                        TranslationSpec.DATA_FORMAT_TEXT,
                    ),
                )
            } catch (error: RuntimeException) {
                Result.failure(error)
            }

            context.mainExecutor.execute mainCallback@{
                if (!isCurrent(token)) return@mainCallback
                result.fold(
                    onSuccess = { capabilities ->
                        handleCapabilities(token, required, capabilities, onReady)
                    },
                    onFailure = { error ->
                        failPreparation(
                            token,
                            "System translation capability check failed: " +
                                (error.message ?: error.javaClass.simpleName),
                        )
                    },
                )
            }
        }
    }

    fun translate(result: SpokenResult) {
        checkMainThread()
        if (result.lane == ConversationLane.UNKNOWN) return

        val direction = TranslationRoutePlanner.directionForLane(directions, result.lane)
        if (direction == null) {
            events.onTranslationFailure(
                result.text,
                ConversationLane.UNKNOWN,
                "No translation direction is configured for ${result.lane.name.lowercase()}.",
            )
            return
        }
        val translator = translators[direction]
        if (translator == null || translator.isDestroyed) {
            events.onTranslationFailure(
                result.text,
                direction.targetLane,
                "The system translator is not ready.",
            )
            return
        }

        val token = generation
        val cancellation = CancellationSignal()
        cancellationSignals += cancellation
        val request = TranslationRequest.Builder()
            .setFlags(TranslationRequest.FLAG_TRANSLATION_RESULT)
            .setTranslationRequestValues(
                listOf(TranslationRequestValue.forText(result.text)),
            )
            .build()

        try {
            translator.translate(
                request,
                cancellation,
                context.mainExecutor,
                translationCallback@{ response ->
                    cancellationSignals -= cancellation
                    if (!isCurrent(token)) return@translationCallback
                    handleResponse(result.text, direction, response)
                },
            )
        } catch (error: IllegalStateException) {
            cancellationSignals -= cancellation
            events.onTranslationFailure(
                result.text,
                direction.targetLane,
                "System translation session ended: ${error.message ?: "destroyed"}",
            )
        }
    }

    fun openSettings(): Boolean {
        checkMainThread()
        val intent: PendingIntent = manager?.onDeviceTranslationSettingsActivityIntent ?: return false
        return try {
            intent.send()
            true
        } catch (_: PendingIntent.CanceledException) {
            false
        }
    }

    fun stop() {
        checkMainThread()
        generation += 1
        stopInternal()
    }

    fun close() {
        checkMainThread()
        if (closed) return
        closed = true
        generation += 1
        stopInternal()
        worker.shutdownNow()
    }

    private fun handleCapabilities(
        token: Int,
        required: List<TranslationDirection>,
        capabilities: Set<TranslationCapability>,
        onReady: () -> Unit,
    ) {
        val selected = required.associateWith { direction ->
            bestCapability(direction, capabilities)
        }

        events.onTranslationCapabilityReport(
            buildString {
                appendLine("SYSTEM TRANSLATION SERVICE: available")
                required.forEach { direction ->
                    val capability = selected[direction]
                    append("${direction.sourceLanguageTag} → ${direction.targetLanguageTag}: ")
                    if (capability == null) {
                        appendLine("not supported")
                    } else {
                        append(capability.sourceSpec.locale.toLanguageTag())
                        append(" → ")
                        append(capability.targetSpec.locale.toLanguageTag())
                        append(" · ")
                        append(stateName(capability.state))
                        val requestedScript =
                            TranslationLocalePolicy.requestedChineseOutputScript(direction.targetLanguageTag)
                        if (capability.targetSpec.locale.toLanguageTag() == "zh" && requestedScript != null) {
                            append(" · normalize output to ${requestedScript.name.lowercase()}")
                        }
                        appendLine()
                    }
                }
            }.trimEnd(),
        )

        val missing = selected.filterValues { it == null }.keys
        if (missing.isNotEmpty()) {
            failPreparation(
                token,
                "No system on-device translation capability was reported for " +
                    missing.joinToString { "${it.sourceLanguageTag} → ${it.targetLanguageTag}" } +
                    ".",
            )
            return
        }

        val resolved = required.map { direction -> direction to checkNotNull(selected[direction]) }
        createTranslators(token, resolved, index = 0, onReady = onReady)
    }

    private fun createTranslators(
        token: Int,
        selected: List<Pair<TranslationDirection, TranslationCapability>>,
        index: Int,
        onReady: () -> Unit,
    ) {
        if (!isCurrent(token)) return
        if (index >= selected.size) {
            events.onTranslationStatus("System translation ready on device")
            onReady()
            return
        }

        val (direction, capability) = selected[index]
        if (capability.state != TranslationCapability.STATE_ON_DEVICE) {
            val state = stateName(capability.state)
            failPreparation(
                token,
                "${direction.sourceLanguageTag} → ${direction.targetLanguageTag} is $state. " +
                    "Install it in Android's system translation settings, then retry.",
            )
            return
        }
        events.onTranslationStatus(
            "Opening ${direction.sourceLanguageTag} → ${direction.targetLanguageTag} translator…",
        )

        val supportedFlags = capability.supportedTranslationFlags
        val flags = supportedFlags and TranslationContext.FLAG_LOW_LATENCY
        val translationContext = TranslationContext.Builder(
            capability.sourceSpec,
            capability.targetSpec,
        ).setTranslationFlags(flags).build()

        checkNotNull(manager).createOnDeviceTranslator(
            translationContext,
            context.mainExecutor,
        ) { translator ->
            if (!isCurrent(token)) {
                translator?.destroy()
                return@createOnDeviceTranslator
            }
            if (translator == null) {
                failPreparation(
                    token,
                    "Android could not create the ${direction.sourceLanguageTag} → " +
                        "${direction.targetLanguageTag} on-device translator.",
                )
                return@createOnDeviceTranslator
            }

            translators[direction] = translator
            createTranslators(token, selected, index + 1, onReady)
        }
    }

    private fun handleResponse(
        sourceText: String,
        direction: TranslationDirection,
        response: TranslationResponse,
    ) {
        if (response.translationStatus != TranslationResponse.TRANSLATION_STATUS_SUCCESS) {
            events.onTranslationFailure(
                sourceText,
                direction.targetLane,
                when (response.translationStatus) {
                    TranslationResponse.TRANSLATION_STATUS_CONTEXT_UNSUPPORTED ->
                        "The system translation context became unavailable."
                    else -> "The system translation service returned an error."
                },
            )
            return
        }

        val value = response.translationResponseValues[0]
        val translated = value
            ?.takeIf { it.statusCode == TranslationResponseValue.STATUS_SUCCESS }
            ?.text
            ?.toString()
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.let { SystemChineseNormalizer.normalize(it, direction.targetLanguageTag) }
        if (translated == null) {
            events.onTranslationFailure(
                sourceText,
                direction.targetLane,
                "The system translator returned no text.",
            )
            return
        }

        events.onTranslationResult(
            TranslatedResult(
                sourceText = sourceText,
                translatedText = translated,
                sourceLanguageTag = direction.sourceLanguageTag,
                targetLanguageTag = direction.targetLanguageTag,
                sourceLane = direction.sourceLane,
                targetLane = direction.targetLane,
            ),
        )
    }

    private fun bestCapability(
        direction: TranslationDirection,
        capabilities: Set<TranslationCapability>,
    ): TranslationCapability? = capabilities
        .asSequence()
        .filter { capability ->
            TranslationLocalePolicy.capabilityCovers(
                direction.sourceLanguageTag,
                capability.sourceSpec.locale.toLanguageTag(),
            ) && TranslationLocalePolicy.capabilityCovers(
                direction.targetLanguageTag,
                capability.targetSpec.locale.toLanguageTag(),
            )
        }
        .maxWithOrNull(
            compareBy<TranslationCapability> { capability ->
                stateRank(capability.state)
            }.thenBy { capability ->
                exactLocaleScore(direction, capability)
            },
        )

    private fun exactLocaleScore(
        direction: TranslationDirection,
        capability: TranslationCapability,
    ): Int {
        var score = 0
        if (LanguagePairRouter.displayTag(direction.sourceLanguageTag) ==
            LanguagePairRouter.displayTag(capability.sourceSpec.locale.toLanguageTag())
        ) {
            score += 1
        }
        if (LanguagePairRouter.displayTag(direction.targetLanguageTag) ==
            LanguagePairRouter.displayTag(capability.targetSpec.locale.toLanguageTag())
        ) {
            score += 1
        }
        return score
    }

    private fun stateRank(state: Int): Int = when (state) {
        TranslationCapability.STATE_ON_DEVICE -> 3
        TranslationCapability.STATE_DOWNLOADING -> 2
        TranslationCapability.STATE_AVAILABLE_TO_DOWNLOAD -> 1
        else -> 0
    }

    private fun stateName(state: Int): String = when (state) {
        TranslationCapability.STATE_ON_DEVICE -> "on device"
        TranslationCapability.STATE_DOWNLOADING -> "downloading"
        TranslationCapability.STATE_AVAILABLE_TO_DOWNLOAD -> "available to download"
        TranslationCapability.STATE_NOT_AVAILABLE -> "not available"
        else -> "unknown state $state"
    }

    private fun failPreparation(token: Int, message: String) {
        if (!isCurrent(token)) return
        generation += 1
        stopInternal()
        events.onTranslationPreparationFailed(message)
    }

    private fun stopInternal() {
        cancellationSignals.forEach(CancellationSignal::cancel)
        cancellationSignals.clear()
        translators.values.forEach { translator ->
            if (!translator.isDestroyed) translator.destroy()
        }
        translators.clear()
        directions = emptyList()
    }

    private fun isCurrent(token: Int): Boolean = !closed && generation == token

    private fun checkMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "SystemTranslationController must be controlled from the main thread"
        }
    }
}
