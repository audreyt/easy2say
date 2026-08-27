(function (global) {
  const STORAGE_KEY = "v2s-home-lang";

  const strings = {
    en: {
      meta: {
        title: "v2s-ios — Private bilingual captions for iPhone and iPad",
        description:
          "Private, on-device bilingual captions for iPhone and iPad. v2s-ios gives source speech and translation equal space, with no accounts, cloud transcription, analytics, or telemetry.",
        ogTitle: "v2s-ios — Two languages. One shared moment.",
        imageAlt: "v2s-ios showing English and Traditional Chinese captions together on an iPhone",
      },
      a11y: {
        skip: "Skip to content",
        brand: "v2s-ios home",
        nav: "Primary navigation",
        menuOpen: "Open menu",
        menuClose: "Close menu",
        langSwitch: "Language",
      },
      nav: {
        features: "Experience",
        howItWorks: "How it works",
        languages: "Languages",
        privacy: "Privacy",
        getStarted: "Build",
        github: "GitHub",
        build: "Build the app",
      },
      hero: {
        badgeOnDevice: "On-device by default",
        badgePlatform: "iOS + iPadOS 26+",
        title: "Two languages.<br><em>One shared moment.</em>",
        lead:
          "v2s-ios listens through the microphone, transcribes and translates on device, and gives both languages equal space — without accounts, cloud transcription, or telemetry.",
        ctaBuild: "Build for iOS",
        ctaSource: "Explore the source",
        artListen: "Listen",
        artUnderstand: "Understand",
        demoSource: "I understand.",
        demoTranslation: "我明白了。",
        imgAlt: "v2s-ios showing English and Traditional Chinese captions together on an iPhone",
        figureKicker: "Caption 01",
        figureCaption: "Original speech and translation share the screen. Neither is treated as a footnote.",
      },
      highlights: {
        h1Title: "Nothing leaves the conversation",
        h1Body:
          "No account, network client, cloud transcription, analytics, or telemetry. Your words remain on the device in your hands.",
        h2Title: "Equal space for both languages",
        h2Body:
          "Source and translation each receive half the screen: stacked in portrait, side by side in landscape.",
        h3Title: "A screen made to share",
        h3Body:
          "Flip the other person’s half across a table, or let landscape mode open the conversation side by side.",
      },
      features: {
        eyebrow: "01 · The experience",
        title: "Designed around the person across from you.",
        lead:
          "Not a transcript squeezed into a utility window. A calm, shared surface for following each other in the moment.",
        f1Title: "Live bilingual canvas",
        f1Body:
          "Original speech and its translation stay visible together, with a clear half of the screen for each.",
        f2Title: "Two-way conversation",
        f2Body:
          "Two people can speak their own languages into one microphone and read the other person’s words in theirs.",
        f3Title: "Across-the-table view",
        f3Body:
          "Flip one half 180 degrees so both people can read naturally with the device placed between them.",
        f4Title: "A graceful noisy-room override",
        f4Body:
          "The app compares both language lanes; if noise confuses it, tap either half to say who has the floor.",
        f5Title: "Local Taigi captions",
        f5Body:
          "A bundled 4-bit Breeze-ASR-26 model offers assistive Taigi-to-Chinese-character captions without a model download.",
        f6Title: "Transcript at hand",
        f6Body:
          "Review the session inside the app, then return to the live view without leaving the private workflow.",
      },
      howItWorks: {
        eyebrow: "02 · How it works",
        title: "From silence to shared understanding in three gestures.",
        step1Title: "Choose both languages",
        step1Body:
          "Set the language being spoken and the subtitle language each person wants to read.",
        step2Title: "Set the screen between you",
        step2Body:
          "Use portrait, landscape, or flip one half for an across-the-table conversation.",
        step3Title: "Speak naturally",
        step3Body:
          "Tap Start. Speech and translation arrive together, entirely inside v2s-ios.",
      },
      inputLangs: {
        eyebrow: "03 · Language coverage",
        title: "The list follows what your device can actually do.",
        lead:
          "v2s-ios asks Apple Speech and Translation for the languages available on the current device. Choices can vary with iOS, hardware, and installed language assets.",
        inputExamples: "Speech and conversation examples",
        outputExamples: "Additional translation examples",
        noteBefore:
          "The picker shows the exact choices available now; Apple may download a language asset before first use. ",
        readmeLink: "Read the full technical notes ↗",
        readmeHref: "https://github.com/audreyt/v2s/blob/main/README.md",
        chipCantonese: "Cantonese",
        chipZh: "Chinese (Simplified)",
        chipZhHant: "Chinese (Traditional)",
        chipEn: "English",
        chipFr: "French",
        chipDe: "German",
        chipAr: "Arabic",
        chipNl: "Dutch",
        chipHi: "Hindi",
        chipId: "Indonesian",
        chipIt: "Italian",
        chipJa: "Japanese",
        chipKo: "Korean",
        chipPt: "Portuguese",
        chipRu: "Russian",
        chipEs: "Spanish",
        chipTh: "Thai",
        chipTr: "Turkish",
        chipUk: "Ukrainian",
        chipVi: "Vietnamese",
        chipTaigi: "Taigi · Chinese-character captions",
      },
      privacy: {
        eyebrow: "04 · Privacy, literally",
        title: "No account. No network client. No tiny print.",
        li1: "Microphone audio and captions are never sent to a v2s server — there is no v2s server.",
        li2: "Speech recognition and translation run on device with Apple’s frameworks and local language assets.",
        li3: "Apple may download a required language asset once; processing then stays on the device.",
        li4: "Voice activity detection and the optional bundled Taigi model run through Apple’s Core ML stack.",
      },
      quickStart: {
        eyebrow: "05 · Build the app",
        title: "From source to your iPhone in one quiet sitting.",
        lead:
          "The iOS experience is built from this fork. Bring Xcode 26, an iOS 26 device or simulator, and your own signing team for a physical device.",
        s1Title: "Prepare",
        s1Body:
          "Install Xcode 26, XcodeGen, and the Hugging Face CLI. A physical device also needs a local development team in Signing & Capabilities.",
        s2Title: "Fetch and generate",
        s2Body:
          "Clone the fork, fetch the pinned Taigi model, and generate the iOS project.",
        s3Title: "Run",
        s3Body:
          "Choose the v2s-ios scheme and an iPhone, iPad, or simulator, then run from Xcode.",
        copy: "Copy",
        copied: "Copied",
        copyFailed: "Failed",
        copyCmds: "Copy build commands",
        permsTitle: "What the first run asks for",
        perm1Title: "Speech Recognition",
        perm1Body: "to turn spoken audio into text",
        perm2Title: "Microphone",
        perm2Body: "to hear the conversation you choose to caption",
        perm3Title: "Language assets",
        perm3Body: "downloaded by Apple only when a selected language needs them",
      },
      fork: {
        eyebrow: "Lineage",
        title: "An iOS-first fork, in the open.",
        body:
          "v2s-ios begins with pull request #20 on franklioxygen/v2s and keeps the original macOS target buildable for shared-engine work. The iPhone and iPad experience is this fork’s focus.",
        upstream: "See the upstream macOS project",
      },
      cta: {
        title: "Let both sides of the conversation stay visible.",
        body: "Open source, on device, and designed for the phone already between you.",
        source: "Open on GitHub",
        readme: "Read the build notes",
        readmeHref: "https://github.com/audreyt/v2s/blob/main/README.md",
      },
      footer: {
        notice: "Fork attribution · ",
        docLink: "繁體中文 README",
        docHref: "https://github.com/audreyt/v2s/blob/main/README.zh-Hant.md",
        upstream: "Upstream macOS project ↗",
      },
    },

    zh: {
      meta: {
        title: "v2s-ios — iPhone 與 iPad 私密雙語字幕",
        description:
          "iPhone 與 iPad 上私密、於裝置端處理的雙語字幕。v2s-ios 讓原文與譯文平分畫面，不設帳號、不使用雲端轉寫，也沒有分析或遙測。",
        ogTitle: "v2s-ios — 兩種語言，同一個當下。",
        imageAlt: "v2s-ios 在 iPhone 上並列顯示英文原文與繁體中文字幕",
      },
      a11y: {
        skip: "跳至主要內容",
        brand: "v2s-ios 首頁",
        nav: "主要導覽",
        menuOpen: "開啟選單",
        menuClose: "關閉選單",
        langSwitch: "語言",
      },
      nav: {
        features: "體驗",
        howItWorks: "使用方式",
        languages: "語言",
        privacy: "隱私",
        getStarted: "建置",
        github: "GitHub",
        build: "建置應用程式",
      },
      hero: {
        badgeOnDevice: "預設於裝置端處理",
        badgePlatform: "iOS + iPadOS 26+",
        title: "兩種語言，<br><em>同一個當下。</em>",
        lead:
          "v2s-ios 透過麥克風聆聽，在裝置端辨識語音並翻譯，讓原文與譯文各佔一半畫面。沒有帳號、雲端轉寫，也不追蹤你。",
        ctaBuild: "建置 iOS 版",
        ctaSource: "查看原始碼",
        artListen: "聽見",
        artUnderstand: "理解",
        demoSource: "I understand.",
        demoTranslation: "我明白了。",
        imgAlt: "v2s-ios 在 iPhone 上並列顯示英文原文與繁體中文字幕",
        figureKicker: "字幕 01",
        figureCaption: "原文與譯文共享同一面畫面；任何一種語言，都不是註腳。",
      },
      highlights: {
        h1Title: "對話，不離開裝置",
        h1Body:
          "不設帳號，沒有網路用戶端、雲端轉寫、分析或遙測。你說的話，只留在手中的裝置。",
        h2Title: "兩種語言，同樣重要",
        h2Body:
          "原文與譯文各佔一半畫面：直向時上下排列，橫向時左右並排。",
        h3Title: "一面可以共享的畫面",
        h3Body:
          "隔桌時可將對方那一半上下翻轉；改用橫向，對話便在左右兩側展開。",
      },
      features: {
        eyebrow: "01 · 使用體驗",
        title: "設計的起點，是坐在你對面的人。",
        lead:
          "不是把逐字稿硬塞進工具視窗，而是一個安靜、共享的畫面，讓彼此在當下跟得上。",
        f1Title: "雙語即時畫面",
        f1Body:
          "原文與譯文同時留在眼前，各自擁有清楚、完整的一半畫面。",
        f2Title: "雙向對話",
        f2Body:
          "兩人對著同一支麥克風，各自說自己的語言，也各自讀到聽得懂的譯文。",
        f3Title: "隔桌閱讀",
        f3Body:
          "將其中一半旋轉 180 度，裝置放在兩人之間，雙方都能自然閱讀。",
        f4Title: "吵雜時，輕觸接手",
        f4Body:
          "應用程式會比較兩種語言的辨識結果；環境太吵時，輕觸任一半即可指定發言方。",
        f5Title: "裝置端台語字幕",
        f5Body:
          "內建 4 位元 Breeze-ASR-26 模型，不需另行下載；結果為輔助用華文漢字轉寫。",
        f6Title: "字幕記錄隨手可查",
        f6Body:
          "在應用程式內回顧這次對話，再回到即時畫面；整段流程不離開私密環境。",
      },
      howItWorks: {
        eyebrow: "02 · 使用方式",
        title: "從安靜，到聽懂彼此，只要三個動作。",
        step1Title: "選好兩邊的語言",
        step1Body:
          "設定正在說的語言，以及每一方想閱讀的字幕語言。",
        step2Title: "把畫面放在彼此之間",
        step2Body:
          "使用直向、橫向，或翻轉其中一半，配合當下的對話位置。",
        step3Title: "自然開口",
        step3Body:
          "點一下「開始」，原文與譯文便會一起出現在 v2s-ios 裡。",
      },
      inputLangs: {
        eyebrow: "03 · 語言支援",
        title: "可用語言，以這台裝置當下的能力為準。",
        lead:
          "v2s-ios 會向 Apple Speech 與 Translation 查詢目前裝置可用的語言。選項可能隨 iOS 版本、硬體與已安裝的語言資源而異。",
        inputExamples: "語音與雙向對話語言（舉例）",
        outputExamples: "其他翻譯語言（舉例）",
        noteBefore:
          "語言選單會顯示當下確實可用的選項；首次使用前，Apple 可能需要下載語言資源。 ",
        readmeLink: "閱讀完整技術說明 ↗",
        readmeHref: "https://github.com/audreyt/v2s/blob/main/README.zh-Hant.md",
        chipCantonese: "粵語",
        chipZh: "簡體中文",
        chipZhHant: "繁體中文",
        chipEn: "英文",
        chipFr: "法文",
        chipDe: "德文",
        chipAr: "阿拉伯文",
        chipNl: "荷蘭文",
        chipHi: "印地文",
        chipId: "印尼文",
        chipIt: "義大利文",
        chipJa: "日文",
        chipKo: "韓文",
        chipPt: "葡萄牙文",
        chipRu: "俄文",
        chipEs: "西班牙文",
        chipTh: "泰文",
        chipTr: "土耳其文",
        chipUk: "烏克蘭文",
        chipVi: "越南文",
        chipTaigi: "台語 · 華文漢字轉寫",
      },
      privacy: {
        eyebrow: "04 · 隱私，照字面理解",
        title: "沒有帳號。沒有網路用戶端。也沒有小字條款。",
        li1: "麥克風音訊與字幕不會送到 v2s 伺服器——因為根本沒有這種伺服器。",
        li2: "語音辨識與翻譯透過 Apple 框架與本機語言資源，在裝置端執行。",
        li3: "Apple 可能會先下載一次必要的語言資源；之後的處理留在裝置上。",
        li4: "語音活動偵測與選用的內建台語模型，皆透過 Apple Core ML 執行。",
      },
      quickStart: {
        eyebrow: "05 · 建置應用程式",
        title: "從原始碼到你的 iPhone，一次專心建置就能跑起來。",
        lead:
          "這個 iOS 版要從本分支建置。請準備 Xcode 26、iOS 26 裝置或模擬器；若要安裝到實體裝置，還需要自己的簽署團隊。",
        s1Title: "準備環境",
        s1Body:
          "安裝 Xcode 26、XcodeGen 與 Hugging Face CLI。實體裝置還需在 Signing & Capabilities 選擇本機開發團隊。",
        s2Title: "取得並產生專案",
        s2Body:
          "複製此分支、取得固定版本的台語模型，再產生 iOS 專案。",
        s3Title: "執行",
        s3Body:
          "選擇 v2s-ios scheme 與 iPhone、iPad 或模擬器，接著從 Xcode 執行。",
        copy: "複製",
        copied: "已複製",
        copyFailed: "複製失敗",
        copyCmds: "複製建置指令",
        permsTitle: "首次執行會詢問",
        perm1Title: "語音辨識",
        perm1Body: "將你選擇的語音轉為文字",
        perm2Title: "麥克風",
        perm2Body: "聆聽你選擇要加上字幕的對話",
        perm3Title: "語言資源",
        perm3Body: "只有所選語言需要時，才由 Apple 下載",
      },
      fork: {
        eyebrow: "專案脈絡",
        title: "一個把 iOS 放在第一順位的公開分支。",
        body:
          "v2s-ios 以 franklioxygen/v2s 的 pull request #20 為起點，並保留原始 macOS 目標，供共用引擎開發與迴歸驗證使用。這個分支的重心，是 iPhone 與 iPad 體驗。",
        upstream: "查看上游 macOS 專案",
      },
      cta: {
        title: "讓對話的兩邊，都留在眼前。",
        body: "原始碼公開、於裝置端處理，也為你們之間那支手機而設計。",
        source: "在 GitHub 開啟",
        readme: "閱讀建置說明",
        readmeHref: "https://github.com/audreyt/v2s/blob/main/README.zh-Hant.md",
      },
      footer: {
        notice: "分支歸屬說明 · ",
        docLink: "English README",
        docHref: "https://github.com/audreyt/v2s/blob/main/README.md",
        upstream: "上游 macOS 專案 ↗",
      },
    },
  };

  function getNested(obj, path) {
    return path.split(".").reduce(
      (value, key) => value && Object.prototype.hasOwnProperty.call(value, key) ? value[key] : null,
      obj
    );
  }

  function storedLanguage() {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      return stored === "en" || stored === "zh" ? stored : null;
    } catch {
      return null;
    }
  }

  function detectLang() {
    const stored = storedLanguage();
    if (stored) return stored;
    const candidates = Array.isArray(navigator.languages) && navigator.languages.length
      ? navigator.languages
      : [navigator.language];
    for (const tag of candidates) {
      if (!tag) continue;
      const lower = String(tag).toLowerCase();
      if (lower.startsWith("zh")) return "zh";
      if (lower.startsWith("en")) return "en";
    }
    return "en";
  }

  let currentLang = detectLang();

  function t(key) {
    const localized = currentLang === "zh" ? strings.zh : strings.en;
    return getNested(localized, key) ?? getNested(strings.en, key) ?? "";
  }

  function setMeta(selector, value) {
    const node = document.querySelector(selector);
    if (node && value) node.setAttribute("content", value);
  }

  function applyLang(lang) {
    currentLang = lang === "zh" ? "zh" : "en";
    try {
      localStorage.setItem(STORAGE_KEY, currentLang);
    } catch {}

    document.documentElement.lang = currentLang === "zh" ? "zh-TW" : "en";
    document.documentElement.dataset.lang = currentLang;
    document.title = t("meta.title");

    setMeta('meta[name="description"]', t("meta.description"));
    setMeta('meta[property="og:title"]', t("meta.ogTitle"));
    setMeta('meta[property="og:description"]', t("meta.description"));
    setMeta('meta[property="og:image:alt"]', t("meta.imageAlt"));
    setMeta('meta[property="og:locale"]', currentLang === "zh" ? "zh_TW" : "en_US");
    setMeta('meta[name="twitter:title"]', t("meta.ogTitle"));
    setMeta('meta[name="twitter:description"]', t("meta.description"));

    document.querySelectorAll("[data-i18n]").forEach((element) => {
      const key = element.getAttribute("data-i18n");
      const value = t(key);
      if (!value) return;
      if (element.hasAttribute("data-i18n-html")) {
        element.innerHTML = value;
      } else {
        element.textContent = value;
      }
    });

    document.querySelectorAll("[data-i18n-attr]").forEach((element) => {
      const spec = element.getAttribute("data-i18n-attr");
      if (!spec) return;
      spec.split(";").forEach((pair) => {
        const [attribute, key] = pair.split(":").map((part) => part.trim());
        if (attribute && key) element.setAttribute(attribute, t(key));
      });
    });

    document.querySelectorAll("[data-i18n-href]").forEach((element) => {
      const key = element.getAttribute("data-i18n-href");
      if (key) element.setAttribute("href", t(key));
    });

    document.querySelectorAll(".lang-option").forEach((button) => {
      const active = button.getAttribute("data-lang") === currentLang;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });

    document.dispatchEvent(new CustomEvent("v2s:langchange", { detail: { lang: currentLang } }));
  }

  function initLangToggle() {
    document.querySelectorAll(".lang-option").forEach((button) => {
      button.addEventListener("click", () => {
        const lang = button.getAttribute("data-lang");
        if (lang && lang !== currentLang) applyLang(lang);
      });
    });
  }

  global.V2sI18n = {
    t,
    applyLang,
    initLangToggle,
    getLang: () => currentLang,
    detectLang,
  };

  applyLang(currentLang);
})(window);
