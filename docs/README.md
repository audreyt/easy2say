# Easy2say website

Static bilingual product page continuously deployed from `main` through Cloudflare Pages at **https://easy2say.ai/**.

The page describes the iOS-first `audreyt/easy2say` fork. The upstream macOS product remains at **https://github.com/franklioxygen/v2s**.

Run the localization regression tests from the repository root with Node.js (no extra dependencies):

```sh
node --test Tests/Docs/i18n.test.cjs
```
