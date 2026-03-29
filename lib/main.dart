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
/// - [dart:io] — запись файлов на диск и вызов ffmpeg.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_picker/file_picker.dart';

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

/// Состояние [HomePage] — управляет логикой поиска видео и скачивания.
class _HomePageState extends State<HomePage> {
  /// Контроллер текстового поля для ввода YouTube URL.
  final _urlController = TextEditingController();

  /// Клиент YouTube Explode — используется для получения
  /// метаданных видео и потоков для скачивания.
  final _yt = YoutubeExplode();

  // --- Состояние UI ---

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

  @override
  void dispose() {
    _urlController.dispose();
    _yt.close();
    super.dispose();
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
    //final stream = _yt.videos.streamsClient.get(streamInfo);
    final file = File(filePath);
    final fileStream = file.openWrite();

    // Pipe all the content of the stream into the file.
    //await stream.pipe(fileStream);

    final totalBytes = streamInfo.size.totalBytes;
    var receivedBytes = 0;

    // // Читаем поток чанками и записываем в файл,
    // // обновляя прогресс с учётом смещения и веса
    await for (final chunk in stream) {
      fileStream.add(chunk);
      receivedBytes += chunk.length;
      setState(() {
        _downloadProgress =
            progressOffset + (receivedBytes / totalBytes) * progressWeight;
       });
    }

    // Гарантируем, что все данные записаны на диск
    await fileStream.flush();
    await fileStream.close();
  }

  /// Склеивает видео и аудио файлы в один с помощью ffmpeg.
  ///
  /// Использует системный ffmpeg через `Process.run`.
  /// Параметры:
  /// - `-i` — входные файлы (видео и аудио).
  /// - `-c copy` — копирование без перекодирования (максимальная скорость).
  /// - `-y` — перезапись выходного файла без запроса.
  ///
  /// Бросает исключение, если ffmpeg завершился с ошибкой.
  Future<void> _mergeWithFfmpeg(
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    final result = await Process.run('ffmpeg', [
      '-i', videoPath, // Входной видеофайл
      '-i', audioPath, // Входной аудиофайл
      '-c', 'copy', // Копировать потоки без перекодирования
      '-y', // Перезаписать выходной файл, если существует
      outputPath, // Путь для результата
    ]);

    if (result.exitCode != 0) {
      throw Exception('ffmpeg ошибка (код ${result.exitCode}): ${result.stderr}');
    }
  }

  /// Скачивает выбранный видеопоток [info] на диск.
  ///
  /// Для **muxed**-потоков — скачивает один файл напрямую.
  /// Для **adaptive**-потоков:
  /// 1. Скачивает видео и аудио во временные файлы.
  /// 2. Склеивает их через ffmpeg (без перекодирования).
  /// 3. Сохраняет результат в выбранное пользователем место.
  /// 4. Удаляет временные файлы.
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

      setState(() {
        _downloading = false;
        _statusMessage = 'Скачано: $savePath';
      });
    } catch (e) {
      setState(() {
        _downloading = false;
        _statusMessage = 'Ошибка скачивания: $e';
      });
    }
  }

  /// Очищает строку [name] от символов, недопустимых в именах файлов.
  ///
  /// Заменяет символы `\ / : * ? " < > |` на подчёркивание `_`.
  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Donloader')),
      body: Padding(
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
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),

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

            // --- Прогресс скачивания ---
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _downloadProgress),
              const SizedBox(height: 4),
              Text('${(_downloadProgress * 100).toStringAsFixed(1)}%'),
              // Отображаем текущий этап скачивания
              if (_statusMessage != null)
                Text(_statusMessage!,
                    style: const TextStyle(color: Colors.white70)),
            ],

            // --- Статусное сообщение (путь файла или ошибка) ---
            if (_statusMessage != null && !_downloading) ...[
              const SizedBox(height: 16),
              Text(_statusMessage!,
                  style: const TextStyle(color: Colors.greenAccent)),
            ],
          ],
        ),
      ),
    );
  }
}
