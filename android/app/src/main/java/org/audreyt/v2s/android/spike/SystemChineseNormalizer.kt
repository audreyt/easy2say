package org.audreyt.v2s.android.spike

import android.icu.text.Transliterator

/** Makes Android's generic `zh` translation capability honor the requested script. */
object SystemChineseNormalizer {
    private val toTraditional by lazy(LazyThreadSafetyMode.NONE) {
        Transliterator.getInstance("Hans-Hant")
    }
    private val toSimplified by lazy(LazyThreadSafetyMode.NONE) {
        Transliterator.getInstance("Hant-Hans")
    }

    fun normalize(text: String, targetLanguageTag: String): String = when (
        TranslationLocalePolicy.requestedChineseOutputScript(targetLanguageTag)
    ) {
        ChineseOutputScript.TRADITIONAL -> toTraditional.transliterate(text)
        ChineseOutputScript.SIMPLIFIED -> toSimplified.transliterate(text)
        null -> text
    }
}
