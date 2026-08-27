package org.audreyt.v2s.android.spike

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanguagePairRouterTest {
    @Test
    fun routesRegionalVariantsWhenPairLanguagesAreDistinct() {
        assertEquals(
            ConversationLane.PRIMARY,
            LanguagePairRouter.route("en-GB", "en-US", "zh-TW"),
        )
        assertEquals(
            ConversationLane.SECONDARY,
            LanguagePairRouter.route("zh-Hant-HK", "en-US", "zh-TW"),
        )
    }

    @Test
    fun refusesUnknownAndLowInformationTags() {
        assertEquals(
            ConversationLane.UNKNOWN,
            LanguagePairRouter.route(null, "en-US", "zh-TW"),
        )
        assertEquals(
            ConversationLane.UNKNOWN,
            LanguagePairRouter.route("ja-JP", "en-US", "zh-TW"),
        )
    }

    @Test
    fun doesNotConfuseTraditionalAndSimplifiedChineseModels() {
        assertTrue(LanguagePairRouter.covers("zh-TW", listOf("zh-Hant-TW")))
        assertFalse(LanguagePairRouter.covers("zh-TW", listOf("zh-Hans-CN", "zh")))
    }

    @Test
    fun refusesAmbiguousSameLanguageRegionalPair() {
        assertEquals(
            ConversationLane.UNKNOWN,
            LanguagePairRouter.route("en-CA", "en-US", "en-GB"),
        )
    }
}
