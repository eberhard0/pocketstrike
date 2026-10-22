import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Why an image could not be made through Local Dream.
class LocalDreamException implements Exception {
  LocalDreamException(this.message, {this.notReady = false});

  final String message;

  /// Local Dream isn't installed, or no model is open in it.
  final bool notReady;

  @override
  String toString() => message;
}

/// Image generation through Local Dream (github.com/xororz/local-dream), a
/// separate app on the same phone that runs Stable Diffusion on the NPU.
///
/// While a model is open in Local Dream, its native engine serves
/// `http://127.0.0.1:8081` — reachable from this phone only:
///   GET  /health    200 while the engine is up
///   POST /generate  JSON request; the reply is server-sent events:
///                   `data: {"type":"progress","step":n,"total_steps":t}`…,
///                   `data: {"type":"complete","image":<base64>,"format":…}`,
///                   or `data: {"type":"error","message":…}`, then `data: [DONE]`.
/// The picture never leaves the phone. Local Dream picks the model; PocketStrike
/// only sends prompts. Its code is CC BY-NC 4.0 — we call it, we don't copy it.
class LocalDreamBridge {
  LocalDreamBridge._();

  static const packageName = 'io.github.xororz.localdream';
  static const _base = 'http://127.0.0.1:8081';
  static const _channel = MethodChannel('com.pocketstrike.app/gallery');

  // Settings for the few-step DMD2 SDXL models (Illustrious v16 DMD2,
  // CyberRealistic v10 DMD2): LCM sampler, guidance off. A full-step model
  // would want ~20 steps and cfg 7, but distilled ones are the fast choice.
  static const _steps = 8;
  static const _cfg = 1.0;
  static const _scheduler = 'lcm';
  static const _negative =
      'lowres, bad anatomy, bad hands, text, error, missing fingers, extra digit, '
      'cropped, worst quality, low quality, jpeg artifacts, signature, watermark, blurry';

  /// True when Local Dream has a model open and its engine answers.
  static Future<bool> isReady() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
        validateStatus: (_) => true,
      ));
      final r = await dio.get<void>('$_base/health');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Opens Local Dream. False when it isn't installed.
  static Future<bool> open() async {
    try {
      return await _channel.invokeMethod<bool>('openApp', {'package': packageName}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Makes one picture and returns it as a PNG in the app's documents folder.
  ///
  /// The open model's size can't be read from the engine, so this asks for the
  /// SDXL size (1024) first and, if the engine rejects that before it starts,
  /// tries the SD1.5 size (512).
  static Future<File> generate({
    required String prompt,
    String aspectRatio = '1:1',
    void Function(int step, int total)? onProgress,
  }) async {
    if (!await isReady()) {
      throw LocalDreamException(
        'Local Dream has no model open. Open Local Dream, tap a model and wait until it has loaded, '
        'then come back and send your prompt again.',
        notReady: true,
      );
    }
    try {
      return await _generate(1024, prompt, aspectRatio, onProgress);
    } on _RejectedBeforeStart catch (first) {
      debugPrint('[LocalDream] 1024 rejected (${first.message}); trying 512');
      try {
        return await _generate(512, prompt, aspectRatio, onProgress);
      } on _RejectedBeforeStart {
        throw LocalDreamException('Local Dream could not make the picture: ${first.message}');
      }
    }
  }

  static String _withQualityTags(String prompt) {
    final p = prompt.trim();
    final lower = p.toLowerCase();
    if (lower.contains('masterpiece') || lower.contains('best quality')) return p;
    return 'masterpiece, best quality, $p';
  }

  static Future<File> _generate(
    int size,
    String prompt,
    String aspectRatio,
    void Function(int step, int total)? onProgress,
  ) async {
    final body = {
      'prompt': _withQualityTags(prompt),
      'negative_prompt': _negative,
      'steps': _steps,
      'cfg': _cfg,
      'scheduler': _scheduler,
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
        '$_base/generate',
        data: jsonEncode(body),
        options: Options(contentType: 'application/json', responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw LocalDreamException('Couldn\'t reach Local Dream: ${e.message ?? e.type.name}', notReady: true);
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
          onProgress?.call((msg['step'] as num?)?.toInt() ?? 0, (msg['total_steps'] as num?)?.toInt() ?? _steps);
        case 'error':
          final message = msg['message']?.toString() ?? 'unknown error';
          if (!started) throw _RejectedBeforeStart(message);
          throw LocalDreamException('Local Dream stopped: $message');
        case 'complete':
          return _save(msg);
      }
    }
    throw LocalDreamException('Local Dream ended without a picture.');
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
    if (b64.isEmpty) throw LocalDreamException('Local Dream sent an empty picture.');
    var bytes = base64Decode(b64);
    final format = msg['format']?.toString() ?? 'raw';
    if (format == 'raw') {
      // Older engines ignore output_format and send raw RGB(A) pixels.
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

/// The engine refused the request before any step ran (e.g. a size the open
/// model doesn't support), so trying again with other settings is safe.
class _RejectedBeforeStart implements Exception {
  _RejectedBeforeStart(this.message);
  final String message;
}
