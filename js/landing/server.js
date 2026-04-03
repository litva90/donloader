const express = require('express');
const Database = require('better-sqlite3');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const path = require('path');
const http = require('http');

const app = express();
const PORT = process.env.PORT || 3000;

// --- Middleware ---

app.use(helmet({
  contentSecurityPolicy: false // разрешаем inline-стили и шрифты в лендинге
}));

app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// Лимит: максимум 5 запросов на email-submit в минуту с одного IP
const emailLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5,
  message: { success: false, error: 'Слишком много запросов. Попробуйте позже.' },
  standardHeaders: true,
  legacyHeaders: false,
});

// Доверяем proxy-заголовкам (для получения реального IP за nginx/reverse-proxy)
app.set('trust proxy', true);

// --- База данных SQLite ---

const db = new Database(path.join(__dirname, 'emails.db'));

// Создаем таблицу, если не существует
db.exec(`
  CREATE TABLE IF NOT EXISTS subscribers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    ip TEXT,
    country TEXT,
    city TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
`);

const insertEmail = db.prepare(`
  INSERT OR IGNORE INTO subscribers (email, ip, country, city)
  VALUES (?, ?, ?, ?)
`);

const countEmails = db.prepare('SELECT COUNT(*) as count FROM subscribers');

// --- Определение страны по IP через ip-api.com (бесплатный, без ключа) ---

function getGeoByIp(ip) {
  return new Promise((resolve) => {
    // ip-api.com работает только по HTTP (бесплатный тариф)
    const cleanIp = ip.replace('::ffff:', ''); // убираем IPv6-обертку
    const url = `http://ip-api.com/json/${cleanIp}?fields=status,country,city&lang=ru`;

    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (json.status === 'success') {
            resolve({ country: json.country, city: json.city });
          } else {
            resolve({ country: 'Unknown', city: 'Unknown' });
          }
        } catch {
          resolve({ country: 'Unknown', city: 'Unknown' });
        }
      });
    }).on('error', () => {
      resolve({ country: 'Unknown', city: 'Unknown' });
    });
  });
}

// --- Роуты ---

// Отдаем лендинг
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'landing_v2.html'));
});

// API: сбор email
app.post('/api/subscribe', emailLimiter, async (req, res) => {
  const { email } = req.body;

  // Валидация email
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ success: false, error: 'Некорректный email' });
  }

  // Определяем IP клиента
  const ip = req.ip || req.connection.remoteAddress || 'Unknown';

  // Определяем страну по IP
  const geo = await getGeoByIp(ip);

  // Сохраняем в БД (INSERT OR IGNORE — дубликаты молча пропускаются)
  const result = insertEmail.run(email, ip, geo.country, geo.city);
  const total = countEmails.get().count;

  if (result.changes > 0) {
    console.log(`[+] Новый подписчик: ${email} | IP: ${ip} | ${geo.country}, ${geo.city} | Всего: ${total}`);
  }

  // Для пользователя всегда успешный ответ — без раскрытия факта дубликата
  res.json({
    success: true,
    total,
    message: total <= 10
      ? `Место #${total} забронировано!`
      : 'Вы в списке! Скидка 40% на запуске.'
  });
});

// API: количество подписчиков (для обновления слотов)
app.get('/api/stats', (req, res) => {
  const total = countEmails.get().count;
  res.json({ total });
});

// --- Админка: просмотр подписчиков ---

const ADMIN_KEY = 'ls_adm_7Xk9Qm2vBwP4rT8n';

const getAllEmails = db.prepare('SELECT * FROM subscribers ORDER BY created_at DESC');

app.get('/api/admin/subscribers', (req, res) => {
  const key = req.query.key || req.headers['x-admin-key'];
  if (key !== ADMIN_KEY) {
    return res.status(403).json({ error: 'Forbidden' });
  }

  const rows = getAllEmails.all();
  const total = rows.length;

  // Если запрос из браузера — отдаем HTML-таблицу
  if (req.headers.accept && req.headers.accept.includes('text/html')) {
    const rowsHtml = rows.map((r, i) => `
      <tr>
        <td>${total - i}</td>
        <td>${r.email}</td>
        <td>${r.ip}</td>
        <td>${r.country}</td>
        <td>${r.city}</td>
        <td>${r.created_at}</td>
      </tr>`).join('');

    return res.send(`<!DOCTYPE html><html><head><meta charset="utf-8">
      <title>Подписчики (${total})</title>
      <style>body{font-family:monospace;background:#0a0a0f;color:#f0eff8;padding:24px}
      table{border-collapse:collapse;width:100%}th,td{border:1px solid #333;padding:8px 12px;text-align:left}
      th{background:#1a1a26}tr:hover{background:#1a1a26}h1{color:#ff5c35}</style></head>
      <body><h1>LoadSnap — Подписчики (${total})</h1>
      <table><tr><th>#</th><th>Email</th><th>IP</th><th>Страна</th><th>Город</th><th>Дата</th></tr>
      ${rowsHtml}</table></body></html>`);
  }

  res.json({ total, subscribers: rows });
});

// Статика (если понадобятся картинки и т.д.)
app.use(express.static(__dirname));

// --- Запуск ---

app.listen(PORT, '0.0.0.0', () => {
  const total = countEmails.get().count;
  console.log(`LoadSnap Landing запущен на http://0.0.0.0:${PORT}`);
  console.log(`Подписчиков в базе: ${total}`);
});
