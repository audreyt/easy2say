package org.audreyt.v2s.android.spike

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TranslationRoutePlannerTest {
    @Test
    fun captionNeedsOnlySourceToTargetDirection() {
        val directions = TranslationRoutePlanner.requiredDirections(
            SpikeConfig(SpikeMode.CAPTION, "en-US", "zh-TW"),
        )

        assertEquals(
            listOf(
                TranslationDirection(
                    sourceLanguageTag = "en-US",
                    targetLanguageTag = "zh-TW",
                    sourceLane = ConversationLane.PRIMARY,
                    targetLane = ConversationLane.SECONDARY,
                ),
            ),
            directions,
        )
    }

    @Test
    fun conversationWarmsBothDirections() {
        val directions = TranslationRoutePlanner.requiredDirections(
            SpikeConfig(SpikeMode.CONVERSATION, "en-US", "zh-TW"),
        )

        assertEquals(2, directions.size)
        assertEquals("zh-TW", directions[0].targetLanguageTag)
        assertEquals(ConversationLane.SECONDARY, directions[0].targetLane)
        assertEquals("en-US", directions[1].targetLanguageTag)
        assertEquals(ConversationLane.PRIMARY, directions[1].targetLane)
    }

    @Test
    fun unroutedSpeechNeverSelectsTranslationDirection() {
        val directions = TranslationRoutePlanner.requiredDirections(
            SpikeConfig(SpikeMode.CONVERSATION, "en-US", "zh-TW"),
        )

        assertNull(
            TranslationRoutePlanner.directionForLane(directions, ConversationLane.UNKNOWN),
        )
    }

    @Test
    fun genericChineseCapabilityCanBackExplicitTraditionalOutput() {
        assertTrue(TranslationLocalePolicy.capabilityCovers("zh-TW", "zh"))
        assertEquals(
            ChineseOutputScript.TRADITIONAL,
            TranslationLocalePolicy.requestedChineseOutputScript("zh-TW"),
        )
    }

    @Test
    fun genericCapabilityExceptionIsChineseOnly() {
        assertFalse(TranslationLocalePolicy.capabilityCovers("ja-JP", "zh"))
        assertEquals(
            ChineseOutputScript.SIMPLIFIED,
            TranslationLocalePolicy.requestedChineseOutputScript("zh-CN"),
        )
    }
}
