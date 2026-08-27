package org.audreyt.v2s.android.spike

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.util.Locale

class MainActivity : Activity(), SpeechSpikeEvents {
    private val background = Color.rgb(8, 11, 16)
    private val panel = Color.rgb(19, 25, 34)
    private val panelBorder = Color.rgb(47, 61, 76)
    private val primaryText = Color.rgb(239, 246, 255)
    private val secondaryText = Color.rgb(158, 173, 190)
    private val accent = Color.rgb(110, 231, 216)
    private val warning = Color.rgb(251, 191, 36)

    private lateinit var controller: SpeechSpikeController
    private lateinit var scrollView: ScrollView
    private lateinit var captionMode: RadioButton
    private lateinit var conversationMode: RadioButton
    private lateinit var primaryLanguage: EditText
    private lateinit var secondaryLanguage: EditText
    private lateinit var secondaryLanguageGroup: View
    private lateinit var startButton: Button
    private lateinit var statusView: TextView
    private lateinit var detectedLanguageView: TextView
    private lateinit var partialView: TextView
    private lateinit var primaryHeader: TextView
    private lateinit var primaryTranscript: TextView
    private lateinit var secondaryHeader: TextView
    private lateinit var secondaryTranscript: TextView
    private lateinit var unknownGroup: View
    private lateinit var unknownTranscript: TextView
    private lateinit var capabilityView: TextView

    private var active = false
    private var pendingConfig: SpikeConfig? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = background
        window.navigationBarColor = background
        setContentView(buildSurface())
        controller = SpeechSpikeController(this, this)
        updateModeSurface()
    }

    override fun onDestroy() {
        controller.close()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MICROPHONE_PERMISSION_REQUEST) return

        val config = pendingConfig
        pendingConfig = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && config != null) {
            clearTranscripts()
            controller.start(config)
        } else {
            onStatus("Microphone permission denied.", active = false)
        }
    }

    override fun onStatus(message: String, active: Boolean) {
        this.active = active
        statusView.text = message
        statusView.setTextColor(if (active) accent else warning)
        startButton.text = if (active) "STOP" else "START ON DEVICE"
        startButton.backgroundTintList = ColorStateList.valueOf(if (active) Color.rgb(190, 70, 70) else accent)
        startButton.setTextColor(if (active) Color.WHITE else Color.rgb(4, 32, 32))
        setInputsEnabled(!active)
    }

    override fun onCapabilityReport(report: String) {
        capabilityView.text = report
    }

    override fun onPartial(result: SpokenResult) {
        val language = result.detectedLanguageTag?.let(LanguagePairRouter::displayTag)
        partialView.text = buildString {
            append("LIVE  ")
            if (language != null) append("[").append(language).append("] ")
            append(result.text)
        }
        partialView.visibility = View.VISIBLE
    }

    override fun onFinal(result: SpokenResult) {
        partialView.text = ""
        partialView.visibility = View.GONE
        val suffix = buildString {
            result.detectedLanguageTag?.let {
                append("  · ").append(LanguagePairRouter.displayTag(it))
            }
            result.confidence?.let {
                append("  · ").append(String.format(Locale.ROOT, "%.0f%%", it * 100f))
            }
        }
        val line = result.text + suffix

        when (result.lane) {
            ConversationLane.PRIMARY -> appendTranscript(primaryTranscript, line)
            ConversationLane.SECONDARY -> appendTranscript(secondaryTranscript, line)
            ConversationLane.UNKNOWN -> {
                unknownGroup.visibility = View.VISIBLE
                appendTranscript(unknownTranscript, line)
            }
        }
        scrollView.post { scrollView.fullScroll(View.FOCUS_DOWN) }
    }

    override fun onLanguageDetection(detection: LanguageDetection) {
        val routing = if (detection.acceptedForRouting) "routed" else "not routed"
        detectedLanguageView.text = buildString {
            append("DETECTED  ")
            append(LanguagePairRouter.displayTag(detection.languageTag))
            append(" · ").append(detection.confidenceLabel)
            append(" · ").append(detection.switchResultLabel)
            append(" · ").append(routing)
            if (detection.alternatives.isNotEmpty()) {
                append("\nAlternatives: ").append(detection.alternatives.joinToString())
            }
        }
    }

    private fun buildSurface(): View {
        scrollView = ScrollView(this).apply {
            setBackgroundColor(this@MainActivity.background)
            isFillViewport = true
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(32))
        }
        scrollView.addView(
            content,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        content.addView(text("v2s", 31f, primaryText, Typeface.BOLD))
        content.addView(text("ANDROID SPEECH PROBE", 12f, accent, Typeface.BOLD).apply {
            letterSpacing = 0.16f
        })
        content.addView(verticalSpace(8))
        content.addView(text(
            "Explicit on-device SpeechRecognizer only. No INTERNET permission and no network fallback.",
            14f,
            secondaryText,
        ))
        content.addView(verticalSpace(18))

        val modeCard = card()
        modeCard.addView(sectionLabel("MODE"))
        val modes = RadioGroup(this).apply {
            orientation = RadioGroup.VERTICAL
        }
        captionMode = radio("One-language live captions", checked = true)
        conversationMode = radio("Automatic two-language conversation", checked = false)
        modes.addView(captionMode)
        modes.addView(conversationMode)
        modes.setOnCheckedChangeListener { _, _ -> updateModeSurface() }
        modeCard.addView(modes)
        content.addView(modeCard)
        content.addView(verticalSpace(12))

        val languageCard = card()
        languageCard.addView(sectionLabel("BCP-47 LANGUAGE TAGS"))
        languageCard.addView(text("Primary", 13f, secondaryText))
        primaryLanguage = languageField("en-US")
        languageCard.addView(primaryLanguage)
        secondaryLanguageGroup = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(verticalSpace(10))
            addView(text("Secondary", 13f, secondaryText))
            secondaryLanguage = languageField("zh-TW")
            addView(secondaryLanguage)
        }
        languageCard.addView(secondaryLanguageGroup)
        content.addView(languageCard)
        content.addView(verticalSpace(14))

        startButton = Button(this).apply {
            text = "START ON DEVICE"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = 0.08f
            isAllCaps = false
            minHeight = dp(54)
            backgroundTintList = ColorStateList.valueOf(accent)
            setTextColor(Color.rgb(4, 32, 32))
            setOnClickListener { toggleSession() }
        }
        content.addView(
            startButton,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)),
        )
        content.addView(verticalSpace(12))

        statusView = boxedText("Ready to probe this device", accent, 15f)
        content.addView(statusView)
        content.addView(verticalSpace(10))

        detectedLanguageView = boxedText("DETECTED  waiting", secondaryText, 13f).apply {
            visibility = View.GONE
        }
        content.addView(detectedLanguageView)

        partialView = boxedText("", accent, 16f).apply {
            visibility = View.GONE
        }
        content.addView(partialView)
        content.addView(verticalSpace(14))

        primaryHeader = sectionLabel("CAPTIONS · en-US")
        content.addView(primaryHeader)
        primaryTranscript = transcriptView("Speak after the recognizer reports Listening on device.")
        content.addView(primaryTranscript)
        content.addView(verticalSpace(14))

        secondaryHeader = sectionLabel("SECONDARY · zh-TW")
        content.addView(secondaryHeader)
        secondaryTranscript = transcriptView("Detected secondary-language utterances appear here.")
        content.addView(secondaryTranscript)
        content.addView(verticalSpace(14))

        unknownGroup = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(sectionLabel("UNROUTED · LOW OR MISSING LANGUAGE CONFIDENCE"))
            unknownTranscript = transcriptView("Low-confidence utterances are not guessed into either lane.")
            addView(unknownTranscript)
            visibility = View.GONE
        }
        content.addView(unknownGroup)
        content.addView(verticalSpace(18))

        content.addView(sectionLabel("DEVICE CAPABILITY RECEIPT"))
        capabilityView = boxedText(
            "Start a session to list installed, downloadable, pending, and ignored-online language models.",
            secondaryText,
            12f,
        ).apply {
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        content.addView(capabilityView)

        return scrollView
    }

    private fun updateModeSurface() {
        if (!::secondaryLanguageGroup.isInitialized) return
        val conversation = conversationMode.isChecked
        secondaryLanguageGroup.visibility = if (conversation) View.VISIBLE else View.GONE
        secondaryHeader.visibility = if (conversation) View.VISIBLE else View.GONE
        secondaryTranscript.visibility = if (conversation) View.VISIBLE else View.GONE
        detectedLanguageView.visibility = if (conversation) View.VISIBLE else View.GONE
        primaryHeader.text = if (conversation) {
            "PRIMARY · ${primaryLanguage.text}"
        } else {
            "CAPTIONS · ${primaryLanguage.text}"
        }
        secondaryHeader.text = "SECONDARY · ${secondaryLanguage.text}"
    }

    private fun toggleSession() {
        if (active) {
            controller.stop()
            return
        }

        val config = validatedConfig() ?: return
        updateHeaders(config)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            clearTranscripts()
            controller.start(config)
        } else {
            pendingConfig = config
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_PERMISSION_REQUEST)
        }
    }

    private fun validatedConfig(): SpikeConfig? {
        val primary = primaryLanguage.text.toString().trim()
        if (!isLanguageTag(primary)) {
            toast("Enter a valid primary BCP-47 language tag.")
            return null
        }

        if (!conversationMode.isChecked) {
            return SpikeConfig(SpikeMode.CAPTION, primary)
        }

        val secondary = secondaryLanguage.text.toString().trim()
        if (!isLanguageTag(secondary)) {
            toast("Enter a valid secondary BCP-47 language tag.")
            return null
        }
        if (LanguagePairRouter.baseLanguage(primary) == LanguagePairRouter.baseLanguage(secondary)) {
            toast("Conversation mode requires two distinct spoken languages.")
            return null
        }

        return SpikeConfig(SpikeMode.CONVERSATION, primary, secondary)
    }

    private fun isLanguageTag(value: String): Boolean {
        if (value.isBlank() || value.contains("_")) return false
        val locale = Locale.forLanguageTag(value)
        return locale.language.isNotBlank() && locale.language != "und"
    }

    private fun updateHeaders(config: SpikeConfig) {
        primaryHeader.text = if (config.mode == SpikeMode.CAPTION) {
            "CAPTIONS · ${LanguagePairRouter.displayTag(config.primaryLanguageTag)}"
        } else {
            "PRIMARY · ${LanguagePairRouter.displayTag(config.primaryLanguageTag)}"
        }
        secondaryHeader.text = "SECONDARY · ${LanguagePairRouter.displayTag(config.secondaryLanguageTag)}"
    }

    private fun clearTranscripts() {
        primaryTranscript.text = ""
        secondaryTranscript.text = ""
        unknownTranscript.text = ""
        unknownGroup.visibility = View.GONE
        partialView.visibility = View.GONE
        detectedLanguageView.text = "DETECTED  waiting"
        capabilityView.text = "Checking…"
    }

    private fun setInputsEnabled(enabled: Boolean) {
        captionMode.isEnabled = enabled
        conversationMode.isEnabled = enabled
        primaryLanguage.isEnabled = enabled
        secondaryLanguage.isEnabled = enabled
    }

    private fun appendTranscript(view: TextView, line: String) {
        if (view.text.isNotEmpty()) view.append("\n\n")
        view.append(line)
        if (view.length() > MAX_TRANSCRIPT_CHARACTERS) {
            view.text = view.text.takeLast(MAX_TRANSCRIPT_CHARACTERS - 2_000)
        }
    }

    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(14))
        background = panelBackground(14f)
    }

    private fun transcriptView(placeholder: String): TextView = boxedText(
        placeholder,
        primaryText,
        18f,
    ).apply {
        minHeight = dp(96)
        gravity = Gravity.TOP
        setTextIsSelectable(true)
    }

    private fun boxedText(value: String, color: Int, size: Float): TextView = text(value, size, color).apply {
        setPadding(dp(14), dp(12), dp(14), dp(12))
        background = panelBackground(10f)
    }

    private fun sectionLabel(value: String): TextView = text(value, 11f, secondaryText, Typeface.BOLD).apply {
        letterSpacing = 0.12f
        setPadding(0, 0, 0, dp(8))
    }

    private fun languageField(initialValue: String): EditText = EditText(this).apply {
        setText(initialValue)
        setTextColor(primaryText)
        setHintTextColor(secondaryText)
        textSize = 17f
        setSingleLine(true)
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        backgroundTintList = ColorStateList.valueOf(accent)
    }

    private fun radio(label: String, checked: Boolean): RadioButton = RadioButton(this).apply {
        text = label
        textSize = 15f
        setTextColor(primaryText)
        isChecked = checked
        buttonTintList = ColorStateList.valueOf(accent)
        setPadding(0, dp(4), 0, dp(4))
    }

    private fun text(
        value: String,
        size: Float,
        color: Int,
        style: Int = Typeface.NORMAL,
    ): TextView = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(color)
        typeface = Typeface.create(Typeface.DEFAULT, style)
        includeFontPadding = false
        setLineSpacing(0f, 1.12f)
    }

    private fun panelBackground(radiusDp: Float): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(radiusDp.toInt()).toFloat()
        setColor(panel)
        setStroke(dp(1), panelBorder)
    }

    private fun verticalSpace(heightDp: Int): View = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(1, dp(heightDp))
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val MICROPHONE_PERMISSION_REQUEST = 4102
        private const val MAX_TRANSCRIPT_CHARACTERS = 20_000
    }
}
