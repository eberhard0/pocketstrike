import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the person should do when no image engine is ready.
enum ImageEngineAction { none, openLocalDream, allowFilesAccess }

/// Why an image could not be made.
class LocalDreamException implements Exception {
  LocalDreamException(this.message, {this.action = ImageEngineAction.none});

  final String message;
  final ImageEngineAction action;

  /// No engine was ready: nothing failed, something needs setting up.
  bool get notReady => action != ImageEngineAction.none;

  @override
  String toString() => message;
}

/// A Local Dream model PocketStrike can run itself (from Download/LocalDream/models).
class ImageModel {
  ImageModel({required this.id, required this.name, required this.size, this.steps, this.cfg, this.scheduler, this.negative});

  factory ImageModel.fromMap(Map<dynamic, dynamic> m) => ImageModel(
        id: m['id'] as String,
        name: m['name'] as String,
        size: (m['size'] as num?)?.toInt() ?? 1024,
        steps: (m['steps'] as num?)?.round(),
        cfg: (m['cfg'] as num?)?.toDouble(),
        scheduler: m['scheduler'] as String?,
        negative: m['negative'] as String?,
      );

  final String id;
  final String name;
  final int size;

  /// The model's own defaults, from the config.json Local Dream downloaded with it.
  final int? steps;
  final double? cfg;
  final String? scheduler;
  final String? negative;
}

/// Pictures made on this phone's NPU with Local Dream's engine
/// (github.com/xororz/local-dream by xororz, CC BY-NC 4.0).
///
/// Two ways in, tried in this order:
/// 1. **Built in.** This build carries Local Dream's engine (see
///    android/.../ImageEngine.kt). It runs a model Local Dream downloaded,
///    from Download/LocalDream/models, and serves http://127.0.0.1:8082.
/// 2. **Local Dream itself**, when a model is open in it: http://127.0.0.1:8081.
///
/// Both speak the same API: GET /health; POST /generate answering with
/// server-sent events (`progress`…, then `complete` with the image, or
/// `error`), then `[DONE]`. Only this phone can reach either port, and the
/// picture never leaves it.
class LocalDreamBridge {
  LocalDreamBridge._();

  static const packageName = 'io.github.xororz.localdream';
  static const _ownBase = 'http://127.0.0.1:8082';
  static const _ldBase = 'http://127.0.0.1:8081';
  static const _gallery = MethodChannel('com.pocketstrike.app/gallery');
  static const _engine = MethodChannel('com.pocketstrike.app/imageengine');
  static const _prefKey = 'image_model_id';

  // Fallbacks when a model has no config.json: right for the few-step DMD2
  // SDXL models (LCM sampler, guidance off).
  static const _steps = 8;
  static const _cfg = 1.0;
  static const _scheduler = 'lcm';
  static const _negative =
      'lowres, bad anatomy, bad hands, text, error, missing fingers, extra digit, '
      'cropped, worst quality, low quality, jpeg artifacts, signature, watermark, blurry';

  // ── The built-in engine ────────────────────────────────────────────────

  static Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _engine.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('[ImageEngine] $method: $e');
      return null;
    }
  }

  static Future<bool> isBundled() async => await _call<bool>('isBundled') ?? false;

  static Future<bool> hasFilesAccess() async => await _call<bool>('hasFilesAccess') ?? false;

  static Future<void> openFilesAccessSettings() => _call<bool>('openFilesAccessSettings');

  static Future<List<ImageModel>> models() async {
    final list = await _call<List<dynamic>>('listModels') ?? const [];
    return list.whereType<Map<dynamic, dynamic>>().map(ImageModel.fromMap).toList();
  }

  /// {running, model, exitCode, log}
  static Future<Map<dynamic, dynamic>> status() async => await _call<Map<dynamic, dynamic>>('status') ?? const {};

  static Future<void> stopEngine() => _call<bool>('stop');

  static Future<String?> selectedModelId() async => (await SharedPreferences.getInstance()).getString(_prefKey);

  static Future<void> selectModel(String id) async {
    await (await SharedPreferences.getInstance()).setString(_prefKey, id);
    // The next picture loads the new model; free the old one now.
    final st = await status();
    if (st['running'] == true && st['model'] != id) await stopEngine();
  }

  /// Opens Local Dream. False when it isn't installed.
  static Future<bool> open() async {
    try {
      return await _gallery.invokeMethod<bool>('openApp', {'package': packageName}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _healthy(String base) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
        validateStatus: (_) => true,
      ));
      final r = await dio.get<void>('$base/health');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Making a picture ───────────────────────────────────────────────────

  /// Makes one picture and returns it as a PNG in the app's documents folder.
  static Future<File> generate({
    required String prompt,
    String aspectRatio = '1:1',
    void Function(int step, int total)? onProgress,
  }) async {
    final model = await _readyOwnEngine();
    if (model != null) {
      try {
        return await _generate(_ownBase, model.size, model, prompt, aspectRatio, onProgress);
      } on _RejectedBeforeStart catch (e) {
        throw LocalDreamException('The image engine refused the request: ${e.message}');
      }
    }
    if (await _healthy(_ldBase)) {
      // Local Dream has a model open; its size isn't visible, so try SDXL's, then SD1.5's.
      try {
        return await _generate(_ldBase, 1024, null, prompt, aspectRatio, onProgress);
      } on _RejectedBeforeStart catch (first) {
        debugPrint('[LocalDream] 1024 rejected (${first.message}); trying 512');
        try {
          return await _generate(_ldBase, 512, null, prompt, aspectRatio, onProgress);
        } on _RejectedBeforeStart {
          throw LocalDreamException('Local Dream could not make the picture: ${first.message}');
        }
      }
    }
    throw await _notReadyReason();
  }

  /// Starts (or reuses) the built-in engine with the chosen model, or null when
  /// there is no built-in engine or no shared model to run.
  static Future<ImageModel?> _readyOwnEngine() async {
    if (!await isBundled() || !await hasFilesAccess()) return null;
    final list = await models();
    if (list.isEmpty) return null;
    final wantedId = await selectedModelId();
    final model = list.firstWhere((m) => m.id == wantedId, orElse: () => list.first);

    final st = await status();
    if (st['running'] == true && st['model'] == model.id && await _healthy(_ownBase)) return model;

    final error = await _call<String>('start', {'model': model.id});
    if (error != null) throw LocalDreamException(error);

    // Loading an SDXL model onto the NPU takes a while the first time.
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await _healthy(_ownBase)) return model;
      final now = await status();
      if (now['running'] != true) {
        final tail = (now['log'] as String? ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList();
        final last = tail.length > 6 ? tail.sublist(tail.length - 6) : tail;
        throw LocalDreamException(
          'The image engine stopped while loading ${model.name} (exit ${now['exitCode']}).'
          '${last.isEmpty ? '' : '\n\n```\n${last.join('\n')}\n```'}',
        );
      }
    }
    throw LocalDreamException('${model.name} took too long to load. Try again.');
  }

  static Future<LocalDreamException> _notReadyReason() async {
    if (await isBundled()) {
      if (!await hasFilesAccess()) {
        return LocalDreamException(
          'PocketStrike makes pictures with the models Local Dream downloaded. To read them it needs '
          '**All files access**: I\'ve opened that setting. Turn it on for PocketStrike, come back, and send your prompt again.',
          action: ImageEngineAction.allowFilesAccess,
        );
      }
      return LocalDreamException(
        'No Local Dream models in **Download/LocalDream** yet. In Local Dream: **⋮ → Settings → Model storage → '
        'Downloads**. That moves its models there, where PocketStrike can use them too. I\'ve opened Local Dream for you.',
        action: ImageEngineAction.openLocalDream,
      );
    }
    return LocalDreamException(
      'Images are made by **Local Dream** on this phone, and it has no model open yet. Open a model in Local Dream, '
      'wait until it has loaded, then send your prompt again.',
      action: ImageEngineAction.openLocalDream,
    );
  }

  static String _withQualityTags(String prompt) {
    final p = prompt.trim();
    final lower = p.toLowerCase();
    if (lower.contains('masterpiece') || lower.contains('best quality')) return p;
    return 'masterpiece, best quality, $p';
  }

  static Future<File> _generate(
    String base,
    int size,
    ImageModel? model,
    String prompt,
    String aspectRatio,
    void Function(int step, int total)? onProgress,
  ) async {
    final steps = model?.steps ?? _steps;
    final body = {
      'prompt': _withQualityTags(prompt),
      'negative_prompt': model?.negative ?? _negative,
      'steps': steps,
      'cfg': model?.cfg ?? _cfg,
      'scheduler': model?.scheduler ?? _scheduler,
      'width': size,
      'height': size,
      'aspect_ratio': aspectRatio,
      'seed': Random().nextInt(1 << 31),
      'denoise_strength': 0.6,
      'use_opencl': false,
      'show_diffusion_process': false,
      'show_diffusion_stride': 1,
      'preview_format': 'jpeg',
      'output_format': 'png',
    };
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(minutes: 3),
      validateStatus: (_) => true,
    ));

    final Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        '$base/generate',
        data: jsonEncode(body),
        options: Options(contentType: 'application/json', responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw LocalDreamException('Couldn\'t reach the image engine: ${e.message ?? e.type.name}');
    }

    final lines = response.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    if (response.statusCode != 200) {
      final text = (await lines.toList()).join('\n');
      throw _RejectedBeforeStart(_errorMessage(text) ?? 'HTTP ${response.statusCode}');
    }

    var started = false;
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      final Map<String, dynamic> msg;
      try {
        msg = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      switch (msg['type']) {
        case 'progress':
          started = true;
          onProgress?.call((msg['step'] as num?)?.toInt() ?? 0, (msg['total_steps'] as num?)?.toInt() ?? steps);
        case 'error':
          final message = msg['message']?.toString() ?? 'unknown error';
          if (!started) throw _RejectedBeforeStart(message);
          throw LocalDreamException('The image engine stopped: $message');
        case 'complete':
          return _save(msg);
      }
    }
    throw LocalDreamException('The image engine ended without a picture.');
  }

  static String? _errorMessage(String text) {
    try {
      final j = jsonDecode(text);
      final e = j is Map ? j['error'] : null;
      if (e is Map && e['message'] != null) return e['message'].toString();
    } catch (_) {}
    return text.trim().isEmpty ? null : text.trim();
  }

  static Future<File> _save(Map<String, dynamic> msg) async {
    final b64 = msg['image']?.toString() ?? '';
    if (b64.isEmpty) throw LocalDreamException('The image engine sent an empty picture.');
    var bytes = base64Decode(b64);
    final format = msg['format']?.toString() ?? 'raw';
    if (format == 'raw') {
      // An engine that ignores output_format sends raw RGB(A) pixels.
      final w = (msg['width'] as num?)?.toInt() ?? 512;
      final h = (msg['height'] as num?)?.toInt() ?? 512;
      final channels = (msg['channels'] as num?)?.toInt() ?? 3;
      final image = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: Uint8List.fromList(bytes).buffer,
        numChannels: channels,
      );
      bytes = Uint8List.fromList(img.encodePng(image));
    }
    final ext = format == 'jpeg' ? 'jpg' : 'png';
    final dir = await getApplicationDocumentsDirectory();
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File('${dir.path}/local_gen_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

/// The engine refused the request before any step ran, so trying again with
/// other settings is safe.
class _RejectedBeforeStart implements Exception {
  _RejectedBeforeStart(this.message);
  final String message;
}
