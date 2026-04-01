/// Donloader Content Script
///
/// Внедряется на страницы YouTube и добавляет кнопку «Видео» над правым
/// верхним углом видеоплеера. При нажатии отображается выпадающий список
/// с доступными форматами и разрешениями из манифеста видео.
///
/// Выбранный формат и URL страницы отправляются в десктопное приложение
/// Donloader через локальный HTTP-сервер (127.0.0.1:18734).
///
/// Кнопка автоматически скрывается в полноэкранном режиме.

(function () {
  'use strict';

  // Порт локального HTTP-сервера Donloader
  const DONLOADER_PORT = 18734;
  const DONLOADER_API = `http://127.0.0.1:${DONLOADER_PORT}`;

  // Состояние расширения
  let btnContainer = null;
  let dropdown = null;
  let isDropdownOpen = false;
  let videoData = null;
  let currentVideoId = null;

  // ---------------------------------------------------------------------------
  // Извлечение данных видео
  // ---------------------------------------------------------------------------

  /// Извлекает ID видео из текущего URL страницы.
  function getVideoId() {
    const url = new URL(window.location.href);
    return url.searchParams.get('v');
  }

  /// Извлекает данные о потоках из манифеста видео.
  ///
  /// Загружает HTML страницы видео через fetch (с куками текущей сессии)
  /// и парсит JSON объект ytInitialPlayerResponse из исходного кода.
  /// Этот подход не зависит от CSP и работает в обоих браузерах.
  async function extractPlayerResponse() {
    try {
      const videoId = getVideoId();
      if (!videoId) return null;

      // Загружаем HTML страницы видео — fetch наследует куки текущего домена
      const response = await fetch(`https://www.youtube.com/watch?v=${videoId}`, {
        credentials: 'same-origin',
      });
      const html = await response.text();

      // Ищем ytInitialPlayerResponse в HTML — YouTube встраивает его в <script> тег
      const match = html.match(/ytInitialPlayerResponse\s*=\s*(\{.+?\});\s*(?:var|const|let)\s/s);
      if (!match) return null;

      const data = JSON.parse(match[1]);
      if (!data || !data.streamingData) return null;

      return {
        title: (data.videoDetails && data.videoDetails.title) || '',
        videoId: (data.videoDetails && data.videoDetails.videoId) || '',
        formats: (data.streamingData.formats || []).map(function (f) {
          return {
            qualityLabel: f.qualityLabel || '',
            mimeType: f.mimeType || '',
            height: f.height || 0,
            width: f.width || 0,
            contentLength: f.contentLength || '0',
            type: 'muxed',
          };
        }),
        adaptiveFormats: (data.streamingData.adaptiveFormats || [])
          .filter(function (f) {
            return f.mimeType && f.mimeType.startsWith('video/');
          })
          .map(function (f) {
            return {
              qualityLabel: f.qualityLabel || '',
              mimeType: f.mimeType || '',
              height: f.height || 0,
              width: f.width || 0,
              contentLength: f.contentLength || '0',
              type: 'adaptive',
            };
          }),
      };
    } catch (e) {
      console.error('Donloader: ошибка извлечения данных видео', e);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Форматирование
  // ---------------------------------------------------------------------------

  /// Форматирует размер файла из байтов в мегабайты.
  function formatSize(bytes) {
    const mb = parseInt(bytes) / (1024 * 1024);
    if (isNaN(mb) || mb === 0) return '';
    return mb.toFixed(1) + ' MB';
  }

  // ---------------------------------------------------------------------------
  // Создание UI
  // ---------------------------------------------------------------------------

  /// Создаёт кнопку «Видео» и выпадающий список над видеоплеером.
  ///
  /// Кнопка размещается над правым верхним углом элемента #movie_player.
  /// Контейнер вставляется в #player с абсолютным позиционированием.
  function createUI() {
    if (btnContainer) return;

    const playerEl = document.querySelector('#player');
    if (!playerEl) return;

    // Устанавливаем relative позиционирование для корректного размещения кнопки
    if (getComputedStyle(playerEl).position === 'static') {
      playerEl.style.position = 'relative';
    }

    // Контейнер для кнопки и выпадающего списка
    btnContainer = document.createElement('div');
    btnContainer.id = 'donloader-container';

    // Кнопка «Видео»
    const btn = document.createElement('button');
    btn.id = 'donloader-btn';
    btn.textContent = 'Видео';
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleDropdown();
    });

    // Выпадающий список форматов
    dropdown = document.createElement('div');
    dropdown.id = 'donloader-dropdown';
    dropdown.style.display = 'none';

    btnContainer.appendChild(btn);
    btnContainer.appendChild(dropdown);
    playerEl.appendChild(btnContainer);
  }

  // ---------------------------------------------------------------------------
  // Логика выпадающего списка
  // ---------------------------------------------------------------------------

  /// Открывает или закрывает выпадающий список форматов.
  ///
  /// При открытии извлекает данные из манифеста видео и отображает
  /// доступные форматы с разрешением, контейнером и размером.
  async function toggleDropdown() {
    if (isDropdownOpen) {
      dropdown.style.display = 'none';
      isDropdownOpen = false;
      return;
    }

    // Показываем индикатор загрузки
    dropdown.innerHTML = '<div class="donloader-loading">Загрузка форматов...</div>';
    dropdown.style.display = 'block';
    isDropdownOpen = true;

    // Извлекаем данные из манифеста видео
    videoData = await extractPlayerResponse();

    if (!videoData) {
      dropdown.innerHTML = '<div class="donloader-error">Не удалось получить данные видео</div>';
      return;
    }

    renderDropdown();
  }

  /// Отрисовывает содержимое выпадающего списка: название видео и форматы.
  function renderDropdown() {
    dropdown.innerHTML = '';

    // Название видео
    const title = document.createElement('div');
    title.className = 'donloader-title';
    title.textContent = videoData.title;
    dropdown.appendChild(title);

    // Разделитель
    const sep = document.createElement('hr');
    sep.className = 'donloader-separator';
    dropdown.appendChild(sep);

    // Объединяем muxed и adaptive форматы
    const allFormats = [
      ...videoData.formats.map((f) => ({ ...f, category: '' })),
      ...videoData.adaptiveFormats.map((f) => ({ ...f, category: ' — HD' })),
    ];

    // Сортируем по разрешению (от высокого к низкому)
    allFormats.sort((a, b) => (b.height || 0) - (a.height || 0));

    // Убираем дубликаты по qualityLabel + type
    const seen = new Set();
    const uniqueFormats = allFormats.filter((f) => {
      const key = f.qualityLabel + f.type;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });

    if (uniqueFormats.length === 0) {
      dropdown.innerHTML += '<div class="donloader-error">Форматы не найдены</div>';
      return;
    }

    // Создаём пункт для каждого формата
    uniqueFormats.forEach((format) => {
      const item = document.createElement('div');
      item.className = 'donloader-item';

      const container = format.mimeType.split(';')[0].split('/')[1] || 'mp4';
      const size = format.contentLength !== '0' ? ` — ${formatSize(format.contentLength)}` : '';
      const hd = format.type === 'adaptive' ? ' — HD' : '';

      item.textContent = `${format.qualityLabel} — ${container}${size}${hd}`;

      item.addEventListener('click', () => {
        sendToApp(format.qualityLabel);
      });

      dropdown.appendChild(item);
    });
  }

  // ---------------------------------------------------------------------------
  // Связь с приложением Donloader
  // ---------------------------------------------------------------------------

  /// Отправляет выбранный формат и URL видео в приложение Donloader.
  ///
  /// Делает GET-запрос к локальному HTTP-серверу приложения.
  /// Если приложение не запущено, показывает уведомление об ошибке.
  async function sendToApp(quality) {
    const url = window.location.href;

    try {
      const response = await fetch(
        `${DONLOADER_API}/download?url=${encodeURIComponent(url)}&quality=${encodeURIComponent(quality)}`,
        { method: 'GET' }
      );

      if (response.ok) {
        dropdown.style.display = 'none';
        isDropdownOpen = false;
        showNotification('Запрос отправлен в Donloader');
      } else {
        showNotification('Ошибка: не удалось отправить запрос', true);
      }
    } catch (e) {
      showNotification('Donloader не запущен. Запустите приложение.', true);
    }
  }

  // ---------------------------------------------------------------------------
  // Уведомления
  // ---------------------------------------------------------------------------

  /// Показывает всплывающее уведомление в правом нижнем углу экрана.
  function showNotification(text, isError = false) {
    const notif = document.createElement('div');
    notif.className = `donloader-notification${isError ? ' donloader-notification-error' : ''}`;
    notif.textContent = text;
    document.body.appendChild(notif);

    setTimeout(() => {
      notif.classList.add('donloader-notification-hide');
      setTimeout(() => notif.remove(), 300);
    }, 3000);
  }

  // ---------------------------------------------------------------------------
  // Полноэкранный режим
  // ---------------------------------------------------------------------------

  /// Скрывает кнопку при переходе в полноэкранный режим
  /// и показывает при выходе из него.
  function handleFullscreen() {
    if (!btnContainer) return;
    const isFullscreen = !!document.fullscreenElement || !!document.webkitFullscreenElement;
    btnContainer.style.display = isFullscreen ? 'none' : '';
  }

  document.addEventListener('fullscreenchange', handleFullscreen);
  document.addEventListener('webkitfullscreenchange', handleFullscreen);

  // ---------------------------------------------------------------------------
  // Закрытие списка по клику вне него
  // ---------------------------------------------------------------------------

  document.addEventListener('click', (e) => {
    if (btnContainer && !btnContainer.contains(e.target) && isDropdownOpen) {
      dropdown.style.display = 'none';
      isDropdownOpen = false;
    }
  });

  // ---------------------------------------------------------------------------
  // Инициализация и SPA-навигация
  // ---------------------------------------------------------------------------

  /// Инициализирует или обновляет UI при переходе на новое видео.
  ///
  /// Вызывается при первой загрузке страницы и при каждой SPA-навигации
  /// (событие yt-navigate-finish).
  function init() {
    const videoId = getVideoId();

    if (!videoId) {
      // Не страница видео — удаляем UI
      if (btnContainer) {
        btnContainer.remove();
        btnContainer = null;
        dropdown = null;
        isDropdownOpen = false;
      }
      currentVideoId = null;
      return;
    }

    if (videoId !== currentVideoId) {
      currentVideoId = videoId;
      videoData = null;

      // Удаляем старый UI
      if (btnContainer) {
        btnContainer.remove();
        btnContainer = null;
        dropdown = null;
        isDropdownOpen = false;
      }

      // Ждём появления плеера и создаём UI
      waitForPlayer();
    }
  }

  /// Ожидает появления элемента #movie_player в DOM,
  /// затем создаёт UI кнопки.
  function waitForPlayer() {
    const check = () => {
      const player = document.querySelector('#movie_player');
      if (player) {
        createUI();
      } else {
        setTimeout(check, 500);
      }
    };
    check();
  }

  // Слушаем SPA-навигацию YouTube
  document.addEventListener('yt-navigate-finish', init);

  // Первичная инициализация
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
