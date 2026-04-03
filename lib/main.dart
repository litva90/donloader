/// Donloader — десктопное Flutter-приложение для скачивания YouTube-видео.
///
/// Основной поток работы:
/// 1. Пользователь вводит URL видео с YouTube.
/// 2. Приложение загружает метаданные и список доступных потоков (качеств).
/// 3. Пользователь выбирает нужное качество.
/// 4. Видео скачивается на диск с отображением прогресса.
///
/// Поддерживаются два типа потоков:
/// - **Muxed** — видео и аудио уже объединены в одном файле (обычно до 720p).
/// - **Adaptive** — видео и аудио скачиваются отдельно, затем склеиваются
///   с помощью ffmpeg. Это позволяет получить высокое качество (1080p, 1440p, 4K).
///
/// Зависимости:
/// - [youtube_explode_dart] — извлечение метаданных и потоков видео с YouTube.
/// - [file_picker] — нативный диалог сохранения файла.
/// - [path_provider] — системная временная директория для промежуточных файлов.
/// - [dart:io] — запись файлов на диск и вызов ffmpeg (Windows fallback).
/// - [ffmpeg_kit_flutter_new] — встроенный ffmpeg для Android, iOS и macOS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

/// Точка входа приложения.
void main() {
  runApp(const DonloaderApp());
}

/// Корневой виджет приложения.
///
/// Настраивает Material 3 тему с тёмной цветовой схемой
/// на основе deep purple и запускает [HomePage].
class DonloaderApp extends StatelessWidget {
  const DonloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Donloader',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

/// Главная страница приложения — содержит поле ввода URL,
/// превью видео, список качеств и индикатор загрузки.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

/// Тип потока: muxed (видео+аудио вместе) или adaptive (раздельные потоки).
enum StreamType {
  /// Видео и аудио уже объединены в одном файле.
  muxed,

  /// Видео и аудио в раздельных потоках — требуется склейка через ffmpeg.
  adaptive,
}

/// Модель данных для одного варианта качества видео.
///
/// Поддерживает два режима:
/// - **Muxed**: [muxedStream] содержит готовый поток с видео и аудио.
/// - **Adaptive**: [videoStream] и [audioStream] содержат раздельные потоки,
///   которые будут склеены через ffmpeg после скачивания.
class _VideoStreamInfo {
  /// Текстовое описание потока: разрешение, формат, размер, тип.
  final String label;

  /// Тип потока: muxed или adaptive.
  final StreamType type;

  /// Muxed-поток (видео + аудио). Заполнен только при [type] == [StreamType.muxed].
  final MuxedStreamInfo? muxedStream;

  /// Video-only поток. Заполнен только при [type] == [StreamType.adaptive].
  final VideoOnlyStreamInfo? videoStream;

  /// Audio-only поток для склейки. Заполнен только при [type] == [StreamType.adaptive].
  final AudioOnlyStreamInfo? audioStream;

  _VideoStreamInfo.muxed({required this.label, required MuxedStreamInfo stream})
      : type = StreamType.muxed,
        muxedStream = stream,
        videoStream = null,
        audioStream = null;

  _VideoStreamInfo.adaptive({
    required this.label,
    required VideoOnlyStreamInfo video,
    required AudioOnlyStreamInfo audio,
  })  : type = StreamType.adaptive,
        muxedStream = null,
        videoStream = video,
        audioStream = audio;

  /// Расширение контейнера для имени файла (например, "mp4", "webm").
  String get containerName {
    switch (type) {
      case StreamType.muxed:
        return muxedStream!.container.name;
      case StreamType.adaptive:
        return videoStream!.container.name;
    }
  }
}

/// Модель скачанного файла для списка загрузок.
class DownloadedFile {
  /// Название видео.
  final String title;

  /// Полный путь к файлу на диске.
  final String filePath;

  /// Дата и время завершения скачивания.
  final DateTime downloadedAt;

  /// Размер файла в байтах.
  final int sizeBytes;

  DownloadedFile({
    required this.title,
    required this.filePath,
    required this.downloadedAt,
    required this.sizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'filePath': filePath,
        'downloadedAt': downloadedAt.toIso8601String(),
        'sizeBytes': sizeBytes,
      };

  factory DownloadedFile.fromJson(Map<String, dynamic> json) => DownloadedFile(
        title: json['title'] as String,
        filePath: json['filePath'] as String,
        downloadedAt: DateTime.parse(json['downloadedAt'] as String),
        sizeBytes: json['sizeBytes'] as int,
      );
}

/// Состояние [HomePage] — управляет логикой поиска видео и скачивания.
class _HomePageState extends State<HomePage> {
  /// Контроллер текстового поля для ввода YouTube URL.
  final _urlController = TextEditingController();

  /// Клиент YouTube Explode — используется для получения
  /// метаданных видео и потоков для скачивания.
  final _yt = YoutubeExplode();

  /// Локальный HTTP-сервер для приёма запросов от браузерных расширений.
  HttpServer? _server;

  // --- Состояние UI ---

  /// Индекс текущей вкладки: 0 — скачивание, 1 — скачанные файлы.
  int _selectedTab = 0;

  /// Название найденного видео (null, пока видео не загружено).
  String? _videoTitle;

  /// URL превью-изображения видео.
  String? _thumbnailUrl;

  /// Список доступных потоков (качеств) для скачивания.
  List<_VideoStreamInfo> _streams = [];

  /// Флаг: идёт загрузка метаданных видео.
  bool _loading = false;

  /// Флаг: идёт скачивание файла.
  bool _downloading = false;

  /// Прогресс скачивания от 0.0 до 1.0.
  double _downloadProgress = 0;

  /// Текст ошибки (null, если ошибок нет).
  String? _error;

  /// Статусное сообщение (путь сохранённого файла или текст ошибки скачивания).
  String? _statusMessage;

  // --- Управление скачиванием (пауза / отмена) ---

  /// Подписка на текущий поток данных для управления паузой/отменой.
  StreamSubscription<List<int>>? _currentSubscription;

  /// Файловый sink текущего скачивания.
  IOSink? _currentFileSink;

  /// Completer для ожидания завершения скачивания потока.
  Completer<void>? _downloadCompleter;

  /// Флаг: скачивание поставлено на паузу.
  bool _isPaused = false;

  /// Флаг: скачивание отменено пользователем.
  bool _isCancelled = false;

  // --- Список скачанных файлов ---

  /// Список скачанных файлов, загружается из JSON при старте.
  List<DownloadedFile> _downloadedFiles = [];

  @override
  void initState() {
    super.initState();
    _startLocalServer();
    _loadDownloadedFiles();
  }

  @override
  void dispose() {
    _server?.close();
    _urlController.dispose();
    _yt.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Persistence — история скачанных файлов
  // ---------------------------------------------------------------------------

  /// Возвращает файл для хранения истории скачанных видео.
  Future<File> get _historyFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/downloaded_files.json');
  }

  /// Загружает список скачанных файлов из JSON-файла на диске.
  Future<void> _loadDownloadedFiles() async {
    try {
      final file = await _historyFile;
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as List;
      setState(() {
        _downloadedFiles =
            json.map((e) => DownloadedFile.fromJson(e as Map<String, dynamic>)).toList();
      });
    } catch (e) {
      debugPrint('Donloader: не удалось загрузить историю: $e');
    }
  }

  /// Сохраняет текущий список скачанных файлов в JSON-файл.
  Future<void> _saveDownloadedFiles() async {
    final file = await _historyFile;
    await file.writeAsString(
      jsonEncode(_downloadedFiles.map((e) => e.toJson()).toList()),
    );
  }

  // ---------------------------------------------------------------------------
  // Управление скачиванием — пауза, возобновление, отмена
  // ---------------------------------------------------------------------------

  /// Ставит текущее скачивание на паузу.
  void _pauseDownload() {
    _currentSubscription?.pause();
    setState(() => _isPaused = true);
  }

  /// Возобновляет скачивание после паузы.
  void _resumeDownload() {
    _currentSubscription?.resume();
    setState(() => _isPaused = false);
  }

  /// Отменяет текущее скачивание и очищает временные ресурсы.
  Future<void> _cancelDownload() async {
    _isCancelled = true;
    await _currentSubscription?.cancel();
    _currentSubscription = null;
    await _currentFileSink?.close();
    _currentFileSink = null;
    if (_downloadCompleter != null && !_downloadCompleter!.isCompleted) {
      _downloadCompleter!.completeError(Exception('Download cancelled'));
    }
    setState(() {
      _downloading = false;
      _isPaused = false;
      _statusMessage = 'Загрузка отменена';
    });
  }

  // ---------------------------------------------------------------------------
  // Локальный HTTP-сервер
  // ---------------------------------------------------------------------------

  /// Запускает локальный HTTP-сервер на порту 18734 для приёма запросов
  /// от браузерных расширений Chrome/Firefox.
  ///
  /// Обрабатывает POST `/download` с JSON-телом `{videoId, title, quality}`.
  /// Расширение передаёт всю необходимую информацию, чтобы приложение
  /// могло мгновенно показать диалог без дополнительного поиска.
  Future<void> _startLocalServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18734);
      _server!.listen((HttpRequest request) async {
        // CORS-заголовки для доступа из браузерного расширения
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

        if (request.method == 'OPTIONS') {
          request.response.statusCode = 200;
          await request.response.close();
          return;
        }

        if (request.uri.path == '/download' && request.method == 'POST') {
          try {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final videoId = data['videoId'] as String?;
            final title = data['title'] as String?;
            final quality = data['quality'] as String?;

            if (videoId != null && title != null && quality != null) {
              request.response
                ..statusCode = 200
                ..write(jsonEncode({'status': 'ok'}));
              await request.response.close();

              _handleExtensionRequest(videoId, title, quality);
            } else {
              request.response
                ..statusCode = 400
                ..write(jsonEncode({'error': 'Missing videoId, title or quality'}));
              await request.response.close();
            }
          } catch (e) {
            request.response
              ..statusCode = 400
              ..write(jsonEncode({'error': 'Invalid JSON'}));
            await request.response.close();
          }
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      });
    } catch (e) {
      debugPrint('Donloader: не удалось запустить HTTP-сервер: $e');
    }
  }

  /// Обрабатывает запрос на скачивание от браузерного расширения.
  ///
  /// Получает videoId, title и quality от расширения. Мгновенно показывает
  /// диалог подтверждения с этими данными. Манифест потоков запрашивается
  /// только после нажатия «Начать загрузку».
  void _handleExtensionRequest(String videoId, String title, String quality) {
    if (!mounted) return;

    setState(() {
      _videoTitle = title;
    });

    _showExtensionDownloadDialog(videoId, title, quality);
  }

  /// Показывает диалог подтверждения для запроса от расширения.
  ///
  /// Отображается мгновенно с данными, полученными от расширения.
  /// При нажатии «Начать загрузку» запрашивает манифест и начинает скачивание.
  void _showExtensionDownloadDialog(String videoId, String title, String quality) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Скачивание видео'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(dialogContext).textTheme.titleSmall,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Text(
              'Качество: $quality',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _downloadFromExtension(videoId, title, quality);
            },
            child: const Text('Начать загрузку'),
          ),
        ],
      ),
    );
  }

  /// Запрашивает манифест по videoId и скачивает поток с указанным разрешением.
  ///
  /// Вызывается после подтверждения пользователем в диалоге.
  /// Находит поток, соответствующий запрошенному качеству, и запускает
  /// стандартный процесс скачивания.
  Future<void> _downloadFromExtension(String videoId, String title, String quality) async {
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _statusMessage = 'Получение потоков...';
    });

    try {
      final manifest = await _yt.videos.streams.getManifest(VideoId(videoId), ytClients: [
        YoutubeApiClient.safari,
        YoutubeApiClient.androidVr,
      ]);

      // Извлекаем числовое разрешение из строки вида "1080p60", "720p" и т.д.
      final qualityHeight = int.tryParse(quality.replaceAll(RegExp(r'[^0-9]'), ''));

      // Собираем все потоки — сначала adaptive (HD), затем muxed
      final allStreams = <_VideoStreamInfo>[];

      final audioStreams = manifest.audioOnly.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final bestAudio = audioStreams.isNotEmpty ? audioStreams.first : null;

      if (bestAudio != null) {
        for (final v in manifest.videoOnly) {
          final totalSize = v.size.totalBytes + bestAudio.size.totalBytes;
          final sizeMb = (totalSize / 1024 / 1024).toStringAsFixed(1);
          allStreams.add(_VideoStreamInfo.adaptive(
            label: '${v.videoResolution.height}p — '
                '${v.container.name} — '
                '$sizeMb MB — HD',
            video: v,
            audio: bestAudio,
          ));
        }
      }

      for (final s in manifest.muxed) {
        final sizeMb = (s.size.totalBytes / 1024 / 1024).toStringAsFixed(1);
        allStreams.add(_VideoStreamInfo.muxed(
          label: '${s.videoResolution.height}p — '
              '${s.container.name} — '
              '$sizeMb MB',
          stream: s,
        ));
      }

      if (allStreams.isEmpty) {
        setState(() {
          _downloading = false;
          _statusMessage = 'Потоки не найдены';
        });
        return;
      }

      // Ищем поток с совпадающим разрешением
      _VideoStreamInfo? selectedStream;
      if (qualityHeight != null) {
        selectedStream = allStreams.cast<_VideoStreamInfo?>().firstWhere(
          (s) => s!.label.startsWith('${qualityHeight}p'),
          orElse: () => null,
        );
      }
      selectedStream ??= allStreams.first;

      setState(() {
        _videoTitle = title;
        _downloading = false;
      });

      await _download(selectedStream);
    } catch (e) {
      setState(() {
        _downloading = false;
        _statusMessage = 'Ошибка: $e';
      });
    }
  }

  /// Загружает метаданные видео и список доступных потоков по URL.
  ///
  /// Получает два типа потоков:
  /// 1. **Muxed** — видео + аудио в одном файле (обычно до 720p).
  /// 2. **Adaptive** — video-only потоки, к которым подбирается лучший
  ///    audio-only поток для последующей склейки через ffmpeg.
  ///
  /// Все потоки объединяются в один список и сортируются по разрешению.
  Future<void> _fetchStreams() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    // Сбрасываем предыдущее состояние перед новым запросом
    setState(() {
      _loading = true;
      _error = null;
      _streams = [];
      _videoTitle = null;
      _thumbnailUrl = null;
      _statusMessage = null;
    });

    try {
      // Получаем метаданные видео (название, превью и т.д.)
      final video = await _yt.videos.get(url);

      // Получаем манифест со списком всех доступных потоков
      final manifest = await _yt.videos.streams.getManifest(video.id, ytClients: [
        YoutubeApiClient.safari,
        YoutubeApiClient.androidVr  
      ]);
      //final manifest = await _yt.videos.streamsClient.getManifest(video.id);

      final allStreams = <_VideoStreamInfo>[];

      // --- Muxed-потоки (видео + аудио уже объединены) ---
      for (final s in manifest.muxed) {
        final sizeMb = (s.size.totalBytes / 1024 / 1024).toStringAsFixed(1);
        allStreams.add(_VideoStreamInfo.muxed(
          label: '${s.videoResolution.height}p — '
              '${s.container.name} — '
              '$sizeMb MB',
          stream: s,
        ));
      }

      // --- Adaptive-потоки (видео и аудио раздельно) ---
      // Находим лучший аудио-поток для склейки (максимальный битрейт).
      final audioStreams = manifest.audioOnly.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final bestAudio = audioStreams.isNotEmpty ? audioStreams.first : null;

      if (bestAudio != null) {
        for (final v in manifest.videoOnly) {
          // Суммарный размер = видео + аудио
          final totalSize = v.size.totalBytes + bestAudio.size.totalBytes;
          final sizeMb = (totalSize / 1024 / 1024).toStringAsFixed(1);
          allStreams.add(_VideoStreamInfo.adaptive(
            label: '${v.videoResolution.height}p — '
                '${v.container.name} — '
                '$sizeMb MB — '
                'HD',
            video: v,
            audio: bestAudio,
          ));
        }
      }

      // Сортируем все потоки по разрешению от высокого к низкому.
      // Для muxed берём разрешение из muxedStream, для adaptive — из videoStream.
      allStreams.sort((a, b) {
        final aHeight = a.type == StreamType.muxed
            ? a.muxedStream!.videoResolution.height
            : a.videoStream!.videoResolution.height;
        final bHeight = b.type == StreamType.muxed
            ? b.muxedStream!.videoResolution.height
            : b.videoStream!.videoResolution.height;
        return bHeight.compareTo(aHeight);
      });

      setState(() {
        _videoTitle = video.title;
        _thumbnailUrl = video.thumbnails.highResUrl;
        _streams = allStreams;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Ошибка: $e';
        _loading = false;
      });
    }
  }

  /// Скачивает один поток в файл, обновляя общий прогресс скачивания.
  ///
  /// Использует [StreamSubscription] вместо `await for`, чтобы поддерживать
  /// паузу, возобновление и отмену скачивания.
  ///
  /// [streamInfo] — метаданные потока из youtube_explode.
  /// [filePath] — путь для сохранения файла.
  /// [progressOffset] — начальное смещение прогресса (0.0–1.0),
  ///   чтобы корректно отображать прогресс при скачивании нескольких файлов.
  /// [progressWeight] — доля этого файла в общем прогрессе (0.0–1.0).
  Future<void> _downloadStream(
    StreamInfo streamInfo,
    String filePath, {
    double progressOffset = 0,
    double progressWeight = 1.0,
  }) async {
    final stream = _yt.videos.streams.get(streamInfo);
    final file = File(filePath);
    final fileStream = file.openWrite();
    _currentFileSink = fileStream;

    final totalBytes = streamInfo.size.totalBytes;
    var receivedBytes = 0;

    _downloadCompleter = Completer<void>();
    _isCancelled = false;

    _currentSubscription = stream.listen(
      (chunk) {
        if (_isCancelled) return;
        fileStream.add(chunk);
        receivedBytes += chunk.length;
        setState(() {
          _downloadProgress =
              progressOffset + (receivedBytes / totalBytes) * progressWeight;
        });
      },
      onDone: () async {
        await fileStream.flush();
        await fileStream.close();
        _currentFileSink = null;
        _currentSubscription = null;
        if (!_downloadCompleter!.isCompleted) {
          _downloadCompleter!.complete();
        }
      },
      onError: (Object error) {
        if (!_downloadCompleter!.isCompleted) {
          _downloadCompleter!.completeError(error);
        }
      },
      cancelOnError: true,
    );

    return _downloadCompleter!.future;
  }

  /// Склеивает видео и аудио файлы в один с помощью ffmpeg.
  ///
  /// Параметры команды:
  /// - `-i` — входные файлы (видео и аудио).
  /// - `-c copy` — копирование без перекодирования (максимальная скорость).
  /// - `-y` — перезапись выходного файла без запроса.
  ///
  /// На Android, iOS и macOS использует встроенный ffmpeg через [FFmpegKit].
  /// На Windows вызывает ffmpeg.exe через [Process.run] — ищет рядом
  /// с приложением (бандл), затем в системном PATH.
  Future<void> _mergeWithFfmpeg(
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    if (Platform.isWindows) {
      // --- Windows: вызов через Process.run (бандл или PATH) ---
      await _mergeWithFfmpegProcess(videoPath, audioPath, outputPath);
    } else {
      // --- Android, iOS, macOS: встроенный ffmpeg через FFmpegKit ---
      final command =
          '-i "$videoPath" -i "$audioPath" -c copy -y "$outputPath"';
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        throw Exception(
          'ffmpeg ошибка (код ${returnCode?.getValue()}): $logs',
        );
      }
    }
  }

  /// Fallback-склейка через системный ffmpeg для Windows.
  ///
  /// Порядок поиска ffmpeg.exe:
  /// 1. Рядом с исполняемым файлом приложения (бандл).
  /// 2. В системном PATH.
  Future<void> _mergeWithFfmpegProcess(
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    final ffmpegPath = await _findFfmpegExecutable();

    final result = await Process.run(ffmpegPath, [
      '-i', videoPath,
      '-i', audioPath,
      '-c', 'copy',
      '-y', outputPath,
    ]);

    if (result.exitCode != 0) {
      throw Exception('ffmpeg ошибка (код ${result.exitCode}): ${result.stderr}');
    }
  }

  /// Определяет путь к ffmpeg.exe на Windows.
  ///
  /// Порядок поиска:
  /// 1. Рядом с exe приложения (для бандла).
  /// 2. В системном PATH.
  Future<String> _findFfmpegExecutable() async {
    // Проверяем ffmpeg.exe рядом с exe приложения
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundledPath = '$exeDir/ffmpeg.exe';
    if (await File(bundledPath).exists()) {
      return bundledPath;
    }

    // Проверяем наличие в системном PATH
    final result = await Process.run('where', ['ffmpeg']);
    if (result.exitCode == 0) {
      return 'ffmpeg';
    }

    throw Exception(
      'ffmpeg.exe не найден. '
      'Поместите ffmpeg.exe рядом с приложением '
      'или установите ffmpeg в системный PATH.',
    );
  }

  /// Скачивает выбранный видеопоток [info] на диск.
  ///
  /// Для **muxed**-потоков — скачивает один файл напрямую.
  /// Для **adaptive**-потоков:
  /// 1. Скачивает видео и аудио во временные файлы.
  /// 2. Склеивает их через ffmpeg (без перекодирования).
  /// 3. Сохраняет результат в выбранное пользователем место.
  /// 4. Удаляет временные файлы.
  ///
  /// После успешного скачивания файл добавляется в историю загрузок.
  Future<void> _download(_VideoStreamInfo info) async {
    // Открываем нативный диалог выбора места сохранения
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Сохранить видео',
      fileName:
          '${_sanitizeFileName(_videoTitle ?? 'video')}.${info.containerName}',
    );

    // Пользователь отменил выбор файла
    if (savePath == null) return;

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _isPaused = false;
      _isCancelled = false;
      _statusMessage = 'Скачивание...';
    });

    try {
      if (info.type == StreamType.muxed) {
        // --- Muxed: простое скачивание одного файла ---
        await _downloadStream(info.muxedStream!, savePath);
      } else {
        // --- Adaptive: скачиваем видео + аудио, затем склеиваем ---

        // Создаём временные файлы для раздельных потоков
        final tempDir = await getTemporaryDirectory();
        final tempVideo =
            '${tempDir.path}/donloader_video_tmp.${info.videoStream!.container.name}';
        final tempAudio =
            '${tempDir.path}/donloader_audio_tmp.${info.audioStream!.container.name}';

        // Рассчитываем доли прогресса пропорционально размерам файлов,
        // чтобы прогресс-бар двигался равномерно
        final videoBytes = info.videoStream!.size.totalBytes;
        final audioBytes = info.audioStream!.size.totalBytes;
        final totalBytes = videoBytes + audioBytes;
        final videoWeight = videoBytes / totalBytes;
        final audioWeight = audioBytes / totalBytes;

        // Скачиваем видео-поток (первая часть прогресса)
        setState(() => _statusMessage = 'Скачивание видео...');
        await _downloadStream(
          info.videoStream!,
          tempVideo,
          progressOffset: 0,
          progressWeight: videoWeight,
        );

        // Скачиваем аудио-поток (вторая часть прогресса)
        setState(() => _statusMessage = 'Скачивание аудио...');
        await _downloadStream(
          info.audioStream!,
          tempAudio,
          progressOffset: videoWeight,
          progressWeight: audioWeight,
        );

        // Склеиваем видео и аудио через ffmpeg
        setState(() => _statusMessage = 'Склейка видео и аудио...');
        await _mergeWithFfmpeg(tempVideo, tempAudio, savePath);

        // Удаляем временные файлы
        await File(tempVideo).delete();
        await File(tempAudio).delete();
      }

      // Записываем файл в историю скачанных
      final fileSize = await File(savePath).length();
      final downloaded = DownloadedFile(
        title: _videoTitle ?? 'video',
        filePath: savePath,
        downloadedAt: DateTime.now(),
        sizeBytes: fileSize,
      );
      _downloadedFiles.insert(0, downloaded);
      await _saveDownloadedFiles();

      setState(() {
        _downloading = false;
        _statusMessage = 'Скачано: $savePath';
      });
    } catch (e) {
      // Очищаем временные файлы при ошибке/отмене для adaptive-потоков
      if (info.type == StreamType.adaptive) {
        final tempDir = await getTemporaryDirectory();
        final tempVideo =
            '${tempDir.path}/donloader_video_tmp.${info.videoStream!.container.name}';
        final tempAudio =
            '${tempDir.path}/donloader_audio_tmp.${info.audioStream!.container.name}';
        try { await File(tempVideo).delete(); } catch (_) {}
        try { await File(tempAudio).delete(); } catch (_) {}
      }
      // Удаляем недокачанный файл при отмене
      if (_isCancelled) {
        try { await File(savePath).delete(); } catch (_) {}
      }

      setState(() {
        _downloading = false;
        _isPaused = false;
        _statusMessage = e.toString().contains('cancelled')
            ? 'Загрузка отменена'
            : 'Ошибка скачивания: $e';
      });
    }
  }

  /// Очищает строку [name] от символов, недопустимых в именах файлов.
  ///
  /// Заменяет символы `\ / : * ? " < > |` на подчёркивание `_`.
  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  // ---------------------------------------------------------------------------
  // Действия со скачанными файлами
  // ---------------------------------------------------------------------------

  /// Открывает видеофайл в системном проигрывателе.
  Future<void> _openFile(DownloadedFile file) async {
    final f = File(file.filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Файл не найден на диске')),
      );
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [file.filePath]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', file.filePath]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [file.filePath]);
    }
  }

  /// Показывает диалог подтверждения и удаляет файл с диска и из истории.
  Future<void> _confirmDelete(DownloadedFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить файл?'),
        content: Text('Файл «${file.title}» будет удалён с диска.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await File(file.filePath).delete();
    } catch (_) {}
    setState(() => _downloadedFiles.remove(file));
    await _saveDownloadedFiles();
  }

  /// Показывает контекстное меню для скачанного файла при правом клике.
  void _showFileContextMenu(Offset position, DownloadedFile file) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx, position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'open',
          child: ListTile(
            leading: Icon(Icons.play_arrow),
            title: Text('Открыть'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete, color: Colors.red),
            title: Text('Удалить'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    ).then((value) {
      if (value == 'open') _openFile(file);
      if (value == 'delete') _confirmDelete(file);
    });
  }

  // ---------------------------------------------------------------------------
  // UI — build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Donloader')),
      body: _selectedTab == 0 ? _buildDownloadPage() : _buildFilesPage(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (i) => setState(() => _selectedTab = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.download),
            label: 'Скачать',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder),
            label: 'Файлы',
          ),
        ],
      ),
    );
  }

  /// Вкладка «Скачать» — поле ввода URL, превью, список качеств, прогресс.
  Widget _buildDownloadPage() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Строка ввода URL и кнопка поиска ---
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Ссылка на YouTube видео',
                    hintText: 'https://www.youtube.com/watch?v=...',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _fetchStreams(),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _loading ? null : _fetchStreams,
                icon: const Icon(Icons.search),
                label: const Text('Найти'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // --- Индикатор загрузки метаданных ---
          if (_loading) const Center(child: CircularProgressIndicator()),

          // --- Сообщение об ошибке ---
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),

          // --- Превью видео и список качеств ---
          if (_videoTitle != null) ...[
            // Превью: миниатюра + название видео
            Row(
              children: [
                if (_thumbnailUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(_thumbnailUrl!,
                        width: 160, height: 90, fit: BoxFit.cover),
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    _videoTitle!,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Выберите качество:'),
            const SizedBox(height: 8),

            // Прокручиваемый список доступных качеств
            Expanded(
              child: ListView.builder(
                itemCount: _streams.length,
                itemBuilder: (context, index) {
                  final s = _streams[index];
                  return ListTile(
                    leading: Icon(
                      // Muxed-потоки показываем обычной иконкой,
                      // adaptive — иконкой HD для визуального отличия
                      s.type == StreamType.muxed
                          ? Icons.video_file
                          : Icons.hd,
                    ),
                    title: Text(s.label),
                    // Блокируем выбор во время активного скачивания
                    onTap: _downloading ? null : () => _download(s),
                  );
                },
              ),
            ),
          ],

          // --- Прогресс скачивания с кнопками управления ---
          if (_downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 4),
            Text('${(_downloadProgress * 100).toStringAsFixed(1)}%'),
            // Отображаем текущий этап скачивания
            if (_statusMessage != null)
              Text(_statusMessage!,
                  style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            // Кнопки паузы/возобновления и отмены
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_isPaused)
                  IconButton(
                    icon: const Icon(Icons.pause_circle_filled, size: 32),
                    tooltip: 'Пауза',
                    onPressed: _pauseDownload,
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.play_circle_filled, size: 32),
                    tooltip: 'Продолжить',
                    onPressed: _resumeDownload,
                  ),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.cancel, size: 32, color: Colors.red),
                  tooltip: 'Отменить загрузку',
                  onPressed: _cancelDownload,
                ),
              ],
            ),
          ],

          // --- Статусное сообщение (путь файла или ошибка) ---
          if (_statusMessage != null && !_downloading) ...[
            const SizedBox(height: 16),
            Text(_statusMessage!,
                style: const TextStyle(color: Colors.greenAccent)),
          ],
        ],
      ),
    );
  }

  /// Вкладка «Файлы» — список скачанных видео с контекстным меню.
  Widget _buildFilesPage() {
    if (_downloadedFiles.isEmpty) {
      return const Center(
        child: Text(
          'Нет скачанных файлов',
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _downloadedFiles.length,
      itemBuilder: (context, index) {
        final file = _downloadedFiles[index];
        final sizeMb = (file.sizeBytes / 1024 / 1024).toStringAsFixed(1);
        final date =
            '${file.downloadedAt.day.toString().padLeft(2, '0')}.'
            '${file.downloadedAt.month.toString().padLeft(2, '0')}.'
            '${file.downloadedAt.year}';

        return GestureDetector(
          onSecondaryTapUp: (details) {
            _showFileContextMenu(details.globalPosition, file);
          },
          child: ListTile(
            leading: const Icon(Icons.video_file, size: 36),
            title: Text(
              file.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('$sizeMb MB — $date'),
            // Двойной клик для открытия
            onTap: () => _openFile(file),
          ),
        );
      },
    );
  }
}
