package org.audreyt.v2s.android.spike


enum class ChineseOutputScript {
    SIMPLIFIED,
    TRADITIONAL,
}

/** Locale matching rules specific to Android's OEM translation service. */
object TranslationLocalePolicy {
    fun capabilityCovers(requestedTag: String, capabilityTag: String): Boolean {
        if (LanguagePairRouter.covers(requestedTag, listOf(capabilityTag))) return true

        // Pixel's TranslationService advertises one generic `zh` capability. Accept it
        // only here; speech-model matching stays strict. Output script is normalized below.
        return LanguagePairRouter.baseLanguage(requestedTag) == "zh" &&
            LanguagePairRouter.displayTag(capabilityTag) == "zh"
    }

    fun requestedChineseOutputScript(targetTag: String): ChineseOutputScript? {
        val normalized = LanguagePairRouter.displayTag(targetTag)
        if (!normalized.startsWith("zh-")) return null
        return when {
            normalized.contains("-Hant") -> ChineseOutputScript.TRADITIONAL
            normalized.contains("-Hans") -> ChineseOutputScript.SIMPLIFIED
            else -> null
        }
    }
}
