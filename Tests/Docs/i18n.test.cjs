const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { runInNewContext } = require("node:vm");

const source = readFileSync(join(__dirname, "../../docs/js/i18n.js"), "utf8");
const html = readFileSync(join(__dirname, "../../docs/index.html"), "utf8");

function createI18n(language, storedLang = null) {
  const storage = new Map();
  if (storedLang !== null) storage.set("v2s-home-lang", storedLang);

  const document = {
    documentElement: { dataset: {} },
    querySelector: () => null,
    querySelectorAll: () => [],
    dispatchEvent: () => {},
  };
  const window = {};

  runInNewContext(source, {
    window,
    document,
    navigator: { language, languages: [language] },
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
    },
    CustomEvent: class {},
  });

  return { i18n: window.V2sI18n, document, storage };
}

test("switches explicitly between English and native zh-TW copy", () => {
  const { i18n, document } = createI18n("en-US");
  const englishTitle = i18n.t("meta.title");

  assert.equal(englishTitle, "v2s-ios — Private bilingual captions for iPhone and iPad");
  assert.equal(document.documentElement.lang, "en");

  i18n.applyLang("zh");
  assert.equal(i18n.t("nav.build"), "建置應用程式");
  assert.match(i18n.t("hero.title"), /兩種語言/);
  assert.doesNotMatch(i18n.t("hero.title"), /两种语言/);
  assert.equal(document.documentElement.lang, "zh-TW");
  assert.equal(document.title, i18n.t("meta.title"));
  assert.match(i18n.t("quickStart.lead"), /本分支建置/);
  assert.doesNotMatch(
    [i18n.t("meta.description"), i18n.t("quickStart.lead"), i18n.t("privacy.title")].join(" "),
    /實時|賬號/
  );
  assert.match(html, />華文<\//);
  assert.doesNotMatch(html, />繁中<\//);

  i18n.applyLang("en");
  assert.equal(i18n.t("meta.title"), englishTitle);
  assert.equal(i18n.t("missing.translation"), "");
});

test("defaults to zh immediately without user interaction when navigator.language is zh", () => {
  const { i18n, document } = createI18n("zh-TW", null);
  assert.equal(i18n.getLang(), "zh");
  assert.equal(document.documentElement.lang, "zh-TW");
  assert.equal(i18n.t("nav.build"), "建置應用程式");
  assert.match(i18n.t("hero.title"), /兩種語言/);
});

test("honors valid stored language preferences", () => {
  assert.equal(createI18n("en-US", "zh").i18n.t("nav.build"), "建置應用程式");
  assert.equal(createI18n("zh-TW", "en").i18n.t("nav.build"), "Build the app");
});

for (const language of ["__proto__", "constructor", "toString", "fr"]) {
  test(`does not select a dictionary for unsupported stored language ${language}`, () => {
    const { i18n, storage } = createI18n("zh-CN", language);
    assert.equal(i18n.getLang(), "zh");
    assert.equal(i18n.t("nav.build"), "建置應用程式");

    i18n.applyLang(language);
    assert.equal(i18n.getLang(), "en");
    assert.equal(i18n.t("nav.build"), "Build the app");
    assert.equal(storage.get("v2s-home-lang"), "en");
  });
}

for (const language of ["zh-TW", "zh-HK", "zh-MO", "zh-CN", "zh-SG", "zh-Hans"]) {
  test(`serves authored Traditional Chinese without a runtime converter for ${language}`, () => {
    const { i18n, document } = createI18n(language);
    assert.equal(i18n.getLang(), "zh");
    assert.equal(document.documentElement.lang, "zh-TW");
    assert.equal(i18n.t("inputLangs.chipZhHant"), "繁體中文");
    assert.equal(
      i18n.t("inputLangs.readmeHref"),
      "https://github.com/audreyt/v2s/blob/main/README.zh-Hant.md"
    );
  });
}

test("provides both English and zh-TW values for every key used by the page", () => {
  const textKeys = [...html.matchAll(/\bdata-i18n="([^"]+)"/g)].map((match) => match[1]);
  const hrefKeys = [...html.matchAll(/\bdata-i18n-href="([^"]+)"/g)].map((match) => match[1]);
  const attrKeys = [...html.matchAll(/\bdata-i18n-attr="([^"]+)"/g)]
    .flatMap((match) => match[1].split(";"))
    .map((pair) => pair.split(":")[1]?.trim())
    .filter(Boolean);
  const keys = [...new Set([...textKeys, ...hrefKeys, ...attrKeys])];

  for (const language of ["en", "zh"]) {
    const { i18n } = createI18n("en-US", language);
    for (const key of keys) {
      assert.notEqual(i18n.t(key), "", `${language} is missing ${key}`);
    }
  }
});
