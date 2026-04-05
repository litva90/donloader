# SEO-оптимизация для loadsnap.online
## Инструкция: что и куда добавить

---

## 1. ФАЙЛЫ ДЛЯ КОРНЯ САЙТА

Загрузи в корень сайта (рядом с index.html):
- `robots.txt`
- `sitemap.xml`

---

## 2. META-ТЕГИ — вставить в <head> файла index.html

Найди в своём HTML секцию `<head>` и ЗАМЕНИ или ДОБАВЬ эти теги.
Если уже есть `<title>` и `<meta name="description">` — замени их на эти.

```html
<!-- SEO: Основные meta-теги -->
<title>LoadSnap — Download Videos & Files in Any Format | 4K, MP3, Cloud Sync</title>
<meta name="description" content="Download videos from YouTube, Twitch, TikTok and 500+ platforms. Choose quality up to 8K, save as MP4, MP3, FLAC. 100GB cloud storage, cross-platform sync. Free trial.">
<meta name="keywords" content="video downloader, download manager, youtube downloader, twitch audio, file downloader, cross-platform, cloud sync, 4K video download, mp3 downloader">
<meta name="author" content="LoadSnap">
<meta name="robots" content="index, follow">
<link rel="canonical" href="https://loadsnap.online/">

<!-- SEO: Open Graph (Facebook, LinkedIn, мессенджеры) -->
<meta property="og:type" content="website">
<meta property="og:url" content="https://loadsnap.online/">
<meta property="og:title" content="LoadSnap — Download Videos & Files Without Limits">
<meta property="og:description" content="Paste a link, pick format and quality, get your file. No ads, no hassle. 500+ platforms, 100GB cloud, all devices.">
<meta property="og:image" content="https://loadsnap.online/og-image.png">
<meta property="og:site_name" content="LoadSnap">
<meta property="og:locale" content="en_US">
<meta property="og:locale:alternate" content="ru_RU">

<!-- SEO: Twitter Card -->
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="LoadSnap — Download Videos & Files Without Limits">
<meta name="twitter:description" content="Paste a link, pick format and quality, get your file. 500+ platforms, 4K/8K, cloud sync.">
<meta name="twitter:image" content="https://loadsnap.online/og-image.png">

<!-- SEO: Дополнительные технические теги -->
<meta name="theme-color" content="#1a1a2e">
<link rel="icon" type="image/png" href="/favicon.png">
```

---

## 3. STRUCTURED DATA (Schema.org) — вставить перед </head>

Это помогает Google показывать красивые карточки в результатах поиска:

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "LoadSnap",
  "url": "https://loadsnap.online",
  "description": "Cross-platform download manager with video quality selection, cloud storage, and device sync",
  "applicationCategory": "UtilitiesApplication",
  "operatingSystem": "Windows, macOS, Linux, iOS, Android",
  "offers": [
    {
      "@type": "Offer",
      "price": "0",
      "priceCurrency": "USD",
      "name": "Free"
    },
    {
      "@type": "Offer",
      "price": "9",
      "priceCurrency": "USD",
      "name": "Pro",
      "billingIncrement": "month"
    },
    {
      "@type": "Offer",
      "price": "49",
      "priceCurrency": "USD",
      "name": "Lifetime"
    }
  ]
}
</script>
```

---

## 4. OG-IMAGE (обязательно!)

Когда кто-то кидает ссылку на loadsnap.online в Twitter, Reddit, Telegram — 
показывается картинка. Без неё — серый прямоугольник, это убивает клики.

Нужно:
- Создать картинку 1200×630 px
- Название: og-image.png
- Содержание: логотип LoadSnap + слоган "Download anything. Any format. Any device."
- Загрузить в корень сайта

Можешь сделать в Figma за 5 минут или попросить меня сгенерировать.

---

## 5. ПОСЛЕ ЗАГРУЗКИ ФАЙЛОВ — Google Search Console

1. Зайди на https://search.google.com/search-console
2. Нажми "Добавить ресурс" → "Префикс URL" → https://loadsnap.online/
3. Подтверди владение (самый простой способ — скачай HTML-файл и загрузи в корень сайта)
4. После подтверждения:
   - Перейди в "Файлы Sitemap" → введи: sitemap.xml → Отправить
   - Перейди в "Проверка URL" → введи https://loadsnap.online/ → "Запросить индексирование"
5. Индексация обычно происходит за 1-3 дня

---

## ЧЕКЛИСТ

- [ ] robots.txt загружен в корень сайта
- [ ] sitemap.xml загружен в корень сайта
- [ ] Meta-теги добавлены в <head>
- [ ] Schema.org JSON-LD добавлен перед </head>
- [ ] og-image.png (1200×630) создан и загружен
- [ ] favicon.png загружен
- [ ] Google Search Console настроен
- [ ] Sitemap отправлен в Search Console
- [ ] Запрошена индексация главной страницы
