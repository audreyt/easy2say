package org.audreyt.v2s.android.spike


data class TranslationDirection(
    val sourceLanguageTag: String,
    val targetLanguageTag: String,
    val sourceLane: ConversationLane,
    val targetLane: ConversationLane,
)

/** Pure routing policy shared by the system translator and unit tests. */
object TranslationRoutePlanner {
    fun requiredDirections(config: SpikeConfig): List<TranslationDirection> {
        val target = config.secondaryLanguageTag ?: return emptyList()
        val forward = TranslationDirection(
            sourceLanguageTag = config.primaryLanguageTag,
            targetLanguageTag = target,
            sourceLane = ConversationLane.PRIMARY,
            targetLane = ConversationLane.SECONDARY,
        )
        if (config.mode == SpikeMode.CAPTION) return listOf(forward)

        return listOf(
            forward,
            TranslationDirection(
                sourceLanguageTag = target,
                targetLanguageTag = config.primaryLanguageTag,
                sourceLane = ConversationLane.SECONDARY,
                targetLane = ConversationLane.PRIMARY,
            ),
        )
    }

    fun directionForLane(
        directions: Collection<TranslationDirection>,
        lane: ConversationLane,
    ): TranslationDirection? = directions.singleOrNull { it.sourceLane == lane }
}
