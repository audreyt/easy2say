package org.audreyt.v2s.android.spike

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import java.util.Locale

class MainActivity : Activity(), SpeechSpikeEvents, SystemTranslationEvents {
    private val background = Color.rgb(8, 11, 16)
    private val panel = Color.rgb(19, 25, 34)
    private val panelBorder = Color.rgb(47, 61, 76)
    private val primaryText = Color.rgb(239, 246, 255)
    private val secondaryText = Color.rgb(158, 173, 190)
    private val accent = Color.rgb(110, 231, 216)
    private val warning = Color.rgb(251, 191, 36)

    private lateinit var controller: SpeechSpikeController
    private lateinit var translationController: SystemTranslationController
    private lateinit var scrollView: ScrollView
    private lateinit var captionMode: RadioButton
    private lateinit var conversationMode: RadioButton
    private lateinit var primaryLanguage: EditText
    private lateinit var secondaryLanguage: EditText
    private lateinit var secondaryLanguageLabel: TextView
    private lateinit var secondaryLanguageGroup: View
    private lateinit var startButton: Button
    private lateinit var statusView: TextView
    private lateinit var translationStatusView: TextView
    private lateinit var translationSettingsButton: Button
    private lateinit var detectedLanguageView: TextView
    private lateinit var partialView: TextView
    private lateinit var primaryHeader: TextView
    private lateinit var primaryTranscript: TextView
    private lateinit var secondaryHeader: TextView
    private lateinit var secondaryTranscript: TextView
    private lateinit var unknownGroup: View
    private lateinit var unknownTranscript: TextView
    private lateinit var capabilityView: TextView
    private lateinit var translationCapabilityView: TextView

    private var active = false
    private var pendingConfig: SpikeConfig? = null
    private var translationReady = false

    private lateinit var audioManager: AudioManager
    private lateinit var audioInputSpinner: Spinner
    private var audioInputDevices: List<AudioDeviceInfo> = emptyList()
    private var selectedAudioInputId = AUDIO_INPUT_SYSTEM_DEFAULT
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            refreshAudioInputChoices()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            refreshAudioInputChoices()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        audioManager = getSystemService(AudioManager::class.java)
        setContentView(buildSurface())
        controller = SpeechSpikeController(this, this)
        translationController = SystemTranslationController(this, this)
        translationSettingsButton.visibility =
            if (translationController.hasSettingsActivity) View.VISIBLE else View.GONE
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, null)
        refreshAudioInputChoices()
        updateModeSurface()
    }

    override fun onDestroy() {
        audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
        audioManager.clearCommunicationDevice()
        controller.close()
        translationController.close()
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
            beginSession(config)
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
        if (translationReady) translationController.translate(result)
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

    override fun onTranslationStatus(message: String) {
        translationStatusView.text = message
        translationStatusView.setTextColor(accent)
    }

    override fun onTranslationCapabilityReport(report: String) {
        translationCapabilityView.text = report
    }

    override fun onTranslationPreparationFailed(message: String) {
        translationReady = false
        translationStatusView.text =
            "$message Translation is degraded; speech continues independently when its model is ready."
        translationStatusView.setTextColor(warning)
    }

    override fun onTranslationResult(result: TranslatedResult) {
        translationStatusView.text =
            "${LanguagePairRouter.displayTag(result.sourceLanguageTag)} → " +
                "${LanguagePairRouter.displayTag(result.targetLanguageTag)} translated on device"
        translationStatusView.setTextColor(accent)
        val line = if (captionMode.isChecked) {
            result.translatedText
        } else {
            "FROM ${LanguagePairRouter.displayTag(result.sourceLanguageTag)}  ${result.translatedText}"
        }
        appendTranscript(transcriptFor(result.targetLane), line)
        scrollView.post { scrollView.fullScroll(View.FOCUS_DOWN) }
    }

    override fun onTranslationFailure(
        sourceText: String,
        targetLane: ConversationLane,
        message: String,
    ) {
        translationStatusView.text = message
        translationStatusView.setTextColor(warning)
        if (targetLane != ConversationLane.UNKNOWN) {
            appendTranscript(transcriptFor(targetLane), "[translation failed] $sourceText")
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
        scrollView.setOnApplyWindowInsetsListener { _, insets ->
            val systemBars = insets.getInsets(WindowInsets.Type.systemBars())
            scrollView.setPadding(
                systemBars.left,
                systemBars.top,
                systemBars.right,
                systemBars.bottom,
            )
            insets
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
            "Android on-device SpeechRecognizer + TranslationManager. " +
                "No INTERNET permission and no app network fallback.",
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
            secondaryLanguageLabel = text("Translation target", 13f, secondaryText)
            addView(secondaryLanguageLabel)
            secondaryLanguage = languageField("zh-TW")
            addView(secondaryLanguage)
        }
        languageCard.addView(secondaryLanguageGroup)
        content.addView(languageCard)
        content.addView(verticalSpace(12))

        val audioInputCard = card()
        audioInputCard.addView(sectionLabel("AUDIO INPUT"))
        audioInputSpinner = Spinner(this).apply {
            backgroundTintList = ColorStateList.valueOf(accent)
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(
                    parent: AdapterView<*>?,
                    view: View?,
                    position: Int,
                    id: Long,
                ) {
                    val chosenId = audioInputDevices.getOrNull(position - 1)?.id
                        ?: AUDIO_INPUT_SYSTEM_DEFAULT
                    if (chosenId == selectedAudioInputId) return
                    selectedAudioInputId = chosenId
                    if (active) applyAudioInputRouting()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
        audioInputCard.addView(audioInputSpinner)
        audioInputCard.addView(verticalSpace(6))
        audioInputCard.addView(text(
            "Best effort: capture belongs to the system SpeechRecognizer service, " +
                "so some devices keep their own microphone routing.",
            12f,
            secondaryText,
        ))
        content.addView(audioInputCard)
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
        translationStatusView = boxedText("SYSTEM TRANSLATION  waiting", secondaryText, 13f)
        content.addView(translationStatusView)
        content.addView(verticalSpace(10))

        translationSettingsButton = Button(this).apply {
            text = "OPEN SYSTEM TRANSLATION SETTINGS"
            textSize = 12f
            isAllCaps = false
            backgroundTintList = ColorStateList.valueOf(panelBorder)
            setTextColor(primaryText)
            setOnClickListener {
                if (!translationController.openSettings()) {
                    toast("System translation settings are unavailable.")
                }
            }
            visibility = View.GONE
        }
        content.addView(translationSettingsButton)

        detectedLanguageView = boxedText("DETECTED  waiting", secondaryText, 13f).apply {
            visibility = View.GONE
        }
        content.addView(detectedLanguageView)

        partialView = boxedText("", accent, 16f).apply {
            visibility = View.GONE
        }
        content.addView(partialView)
        content.addView(verticalSpace(14))

        primaryHeader = sectionLabel("SOURCE · en-US")
        content.addView(primaryHeader)
        primaryTranscript = transcriptView("Final source captions appear here.")
        content.addView(primaryTranscript)
        content.addView(verticalSpace(14))

        secondaryHeader = sectionLabel("TRANSLATION · zh-TW")
        content.addView(secondaryHeader)
        secondaryTranscript = transcriptView("Final on-device translations appear here.")
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

        content.addView(sectionLabel("SPEECH CAPABILITY RECEIPT"))
        capabilityView = boxedText(
            "Start a session to list installed, downloadable, pending, and ignored-online speech models.",
            secondaryText,
            12f,
        ).apply {
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        content.addView(capabilityView)
        content.addView(verticalSpace(14))
        content.addView(sectionLabel("TRANSLATION CAPABILITY RECEIPT"))
        translationCapabilityView = boxedText(
            "Start a session to query the OEM-provided on-device translation service.",
            secondaryText,
            12f,
        ).apply {
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        content.addView(translationCapabilityView)

        return scrollView
    }

    private fun updateModeSurface() {
        if (!::secondaryLanguageGroup.isInitialized) return
        val conversation = conversationMode.isChecked
        secondaryLanguageGroup.visibility = View.VISIBLE
        secondaryHeader.visibility = View.VISIBLE
        secondaryTranscript.visibility = View.VISIBLE
        detectedLanguageView.visibility = if (conversation) View.VISIBLE else View.GONE
        secondaryLanguageLabel.text = if (conversation) "Secondary speaker" else "Translation target"
        primaryHeader.text = if (conversation) {
            "PRIMARY · ${primaryLanguage.text}"
        } else {
            "SOURCE · ${primaryLanguage.text}"
        }
        secondaryHeader.text = if (conversation) {
            "SECONDARY · ${secondaryLanguage.text}"
        } else {
            "TRANSLATION · ${secondaryLanguage.text}"
        }
    }

    private fun toggleSession() {
        if (active) {
            translationReady = false
            translationController.stop()
            controller.stop()
            audioManager.clearCommunicationDevice()
            return
        }

        val config = validatedConfig() ?: return
        updateHeaders(config)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            beginSession(config)
        } else {
            pendingConfig = config
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_PERMISSION_REQUEST)
        }
    }

    private fun beginSession(config: SpikeConfig) {
        clearTranscripts()
        translationReady = false
        applyAudioInputRouting()
        onStatus("Preparing on-device speech…", active = true)
        translationController.prepare(config) {
            translationReady = true
        }
        controller.start(config)
    }

    private fun refreshAudioInputChoices() {
        if (!::audioInputSpinner.isInitialized) return
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .filter { it.type in RELEVANT_AUDIO_INPUT_TYPES }
            .distinctBy { it.id }
        audioInputDevices = devices

        val labels = buildList {
            add("System default")
            devices.forEach { add(audioInputLabel(it)) }
        }
        val adapter = ArrayAdapter(this, android.R.layout.simple_spinner_item, labels)
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        audioInputSpinner.adapter = adapter

        val retainedIndex = devices.indexOfFirst { it.id == selectedAudioInputId }
        if (retainedIndex >= 0) {
            audioInputSpinner.setSelection(retainedIndex + 1)
        } else {
            // The picked device disappeared (or none was picked): follow the system.
            selectedAudioInputId = AUDIO_INPUT_SYSTEM_DEFAULT
            audioInputSpinner.setSelection(0)
            if (active) audioManager.clearCommunicationDevice()
        }
    }

    private fun applyAudioInputRouting() {
        val device = audioInputDevices.firstOrNull { it.id == selectedAudioInputId }
        if (device == null) {
            audioManager.clearCommunicationDevice()
            return
        }
        if (!audioManager.setCommunicationDevice(device)) {
            toast("Could not route audio input to ${device.productName}.")
        }
    }

    private fun audioInputLabel(device: AudioDeviceInfo): String {
        val type = when (device.type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "built-in"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired headset"
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth"
            AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth LE"
            else -> "input"
        }
        return "${device.productName} · $type"
    }

    private fun validatedConfig(): SpikeConfig? {
        val primary = primaryLanguage.text.toString().trim()
        if (!isLanguageTag(primary)) {
            toast("Enter a valid primary BCP-47 language tag.")
            return null
        }

        val secondary = secondaryLanguage.text.toString().trim()
        if (!isLanguageTag(secondary)) {
            toast("Enter a valid translation/secondary BCP-47 language tag.")
            return null
        }
        if (LanguagePairRouter.baseLanguage(primary) == LanguagePairRouter.baseLanguage(secondary)) {
            toast("Source and target must be distinct spoken languages.")
            return null
        }

        val mode = if (conversationMode.isChecked) SpikeMode.CONVERSATION else SpikeMode.CAPTION
        return SpikeConfig(mode, primary, secondary)
    }

    private fun isLanguageTag(value: String): Boolean {
        if (value.isBlank() || value.contains("_")) return false
        val locale = Locale.forLanguageTag(value)
        return locale.language.isNotBlank() && locale.language != "und"
    }

    private fun updateHeaders(config: SpikeConfig) {
        primaryHeader.text = if (config.mode == SpikeMode.CAPTION) {
            "SOURCE · ${LanguagePairRouter.displayTag(config.primaryLanguageTag)}"
        } else {
            "PRIMARY · ${LanguagePairRouter.displayTag(config.primaryLanguageTag)}"
        }
        secondaryHeader.text = if (config.mode == SpikeMode.CAPTION) {
            "TRANSLATION · ${LanguagePairRouter.displayTag(config.secondaryLanguageTag)}"
        } else {
            "SECONDARY · ${LanguagePairRouter.displayTag(config.secondaryLanguageTag)}"
        }
    }

    private fun clearTranscripts() {
        primaryTranscript.text = ""
        secondaryTranscript.text = ""
        unknownTranscript.text = ""
        unknownGroup.visibility = View.GONE
        partialView.visibility = View.GONE
        detectedLanguageView.text = "DETECTED  waiting"
        translationStatusView.text = "Checking system translation…"
        capabilityView.text = "Checking…"
        translationCapabilityView.text = "Checking…"
    }

    private fun setInputsEnabled(enabled: Boolean) {
        captionMode.isEnabled = enabled
        conversationMode.isEnabled = enabled
        primaryLanguage.isEnabled = enabled
        secondaryLanguage.isEnabled = enabled
        translationSettingsButton.isEnabled = enabled
    }

    private fun appendTranscript(view: TextView, line: String) {
        if (view.text.isNotEmpty()) view.append("\n\n")
        view.append(line)
        if (view.length() > MAX_TRANSCRIPT_CHARACTERS) {
            view.text = view.text.takeLast(MAX_TRANSCRIPT_CHARACTERS - 2_000)
        }
    }

    private fun transcriptFor(lane: ConversationLane): TextView = when (lane) {
        ConversationLane.PRIMARY -> primaryTranscript
        ConversationLane.SECONDARY -> secondaryTranscript
        ConversationLane.UNKNOWN -> unknownTranscript
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
        id = View.generateViewId()
        text = label
        textSize = 15f
        setTextColor(primaryText)
        isChecked = checked
        buttonTintList = ColorStateList(
            arrayOf(
                intArrayOf(android.R.attr.state_checked),
                intArrayOf(),
            ),
            intArrayOf(accent, secondaryText),
        )
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
        private const val AUDIO_INPUT_SYSTEM_DEFAULT = -1
        private val RELEVANT_AUDIO_INPUT_TYPES = setOf(
            AudioDeviceInfo.TYPE_BUILTIN_MIC,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }
}
