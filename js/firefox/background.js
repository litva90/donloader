/// Donloader Background Script (Firefox)
///
/// Проксирует запросы от content script к локальному HTTP-серверу Donloader.
/// Необходим, потому что в Firefox fetch из content script выполняется
/// от имени страницы (youtube.com), а не расширения, и запросы к 127.0.0.1
/// блокируются как mixed content.

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'donloader-download') {
    const fetchOptions = {
      method: message.method || 'GET',
    };

    // Поддержка POST-запросов с телом
    if (message.method === 'POST' && message.body) {
      fetchOptions.headers = { 'Content-Type': 'application/json' };
      fetchOptions.body = message.body;
    }

    fetch(message.url, fetchOptions)
      .then((response) => {
        if (response.ok) {
          return response.json().then((data) => ({ ok: true, data }));
        }
        return { ok: false, error: 'HTTP ' + response.status };
      })
      .catch((e) => ({ ok: false, error: e.message }))
      .then((result) => sendResponse(result));

    // Возвращаем true — ответ будет отправлен асинхронно
    return true;
  }
});
