package org.audreyt.v2s.android.spike

import java.util.Locale

enum class ConversationLane {
    PRIMARY,
    SECONDARY,
    UNKNOWN,
}

/** Maps Android's detected BCP-47 tag to one side of a configured language pair. */
object LanguagePairRouter {
    fun route(
        detectedLanguageTag: String?,
        primaryLanguageTag: String,
        secondaryLanguageTag: String,
    ): ConversationLane {
        val detected = canonical(detectedLanguageTag) ?: return ConversationLane.UNKNOWN
        val primary = canonical(primaryLanguageTag) ?: return ConversationLane.UNKNOWN
        val secondary = canonical(secondaryLanguageTag) ?: return ConversationLane.UNKNOWN

        if (detected == primary) return ConversationLane.PRIMARY
        if (detected == secondary) return ConversationLane.SECONDARY

        // A recognizer may return a different region for the same language. Fall back to
        // the base language only when the configured pair has distinct base languages.
        if (primary.language != secondary.language) {
            if (detected.language == primary.language) return ConversationLane.PRIMARY
            if (detected.language == secondary.language) return ConversationLane.SECONDARY
        }

        return ConversationLane.UNKNOWN
    }

    fun covers(requestedLanguageTag: String, availableLanguageTags: Collection<String>): Boolean {
        val requested = canonical(requestedLanguageTag) ?: return false
        return availableLanguageTags.any { candidateTag ->
            val candidate = canonical(candidateTag) ?: return@any false
            if (candidate == requested) return@any true

            if (requested.language == "zh") {
                // A generic `zh` model does not prove Traditional/Simplified fidelity.
                candidate.language == "zh" &&
                    requested.script != null &&
                    candidate.script == requested.script
            } else {
                candidate.language == requested.language
            }
        }
    }

    fun baseLanguage(languageTag: String): String? = canonical(languageTag)?.language

    fun displayTag(languageTag: String?): String = canonical(languageTag)?.displayTag ?: "unknown"

    private fun canonical(languageTag: String?): CanonicalLanguage? {
        val trimmed = languageTag?.trim().orEmpty()
        if (trimmed.isEmpty()) return null

        val locale = Locale.forLanguageTag(trimmed)
        val language = locale.language.lowercase(Locale.ROOT)
        if (language.isEmpty() || language == "und") return null

        val region = locale.country.uppercase(Locale.ROOT).ifEmpty { null }
        var script = locale.script
            .lowercase(Locale.ROOT)
            .replaceFirstChar { it.titlecase(Locale.ROOT) }
            .ifEmpty { null }

        if (language == "zh" && script == null) {
            script = when (region) {
                "TW", "HK", "MO" -> "Hant"
                "CN", "SG" -> "Hans"
                else -> null
            }
        }

        val displayTag = buildString {
            append(language)
            if (script != null) append("-").append(script)
            if (region != null) append("-").append(region)
        }
        return CanonicalLanguage(language, script, region, displayTag)
    }

    private data class CanonicalLanguage(
        val language: String,
        val script: String?,
        val region: String?,
        val displayTag: String,
    )
}
