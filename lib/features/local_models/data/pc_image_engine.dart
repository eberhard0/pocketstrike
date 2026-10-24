import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where pictures are made.
enum ImageEngineChoice { phone, pc }

/// Why the office PC couldn't make a picture. Shown in chat as is.
class PcImageException implements Exception {
  PcImageException(this.message, {this.setup = false});

  final String message;

  /// No address or token yet: send the person to Settings → Image engine.
  final bool setup;

  @override
  String toString() => message;
}

/// One model the PC offers (from its models.json).
class PcImageModel {
  PcImageModel({required this.id, required this.name, required this.kind, required this.size});

  factory PcImageModel.fromJson(Map<String, dynamic> j) => PcImageModel(
        id: j['id'].toString(),
        name: (j['name'] ?? j['id']).toString(),
        kind: (j['kind'] ?? '').toString(),
        size: (j['size'] as num?)?.toInt() ?? 1024,
      );

  final String id;
  final String name;
  final String kind;
  final int size;
}

/// What /health says about the PC.
class PcStatus {
  PcStatus({required this.gpu, required this.vramGb, required this.queue});

  final String gpu;
  final double vramGb;
  final int queue;
}

/// Image generation on the office PC's NVIDIA card, through the small
/// token-guarded server in `pc/imagegen_server.py` (a front for ComfyUI on the
/// PC, reached through a Cloudflare tunnel). The phone sends the prompt,
/// polls until the picture is ready and saves the PNG — the same file-based
/// result as Local Dream, so chat and the agent tool don't care which ran it.
class PcImageEngine {
  PcImageEngine._();

  static const _engineKey = 'image_engine';
  static const _urlKey = 'pc_image_url';
  static const _modelKey = 'pc_image_model';
  static const _tokenKey = 'pc_image_token';
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());

  // ── settings ────────────────────────────────────────────────────────

  static Future<ImageEngineChoice> engine() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_engineKey) == 'pc' ? ImageEngineChoice.pc : ImageEngineChoice.phone;
  }

  static Future<void> setEngine(ImageEngineChoice choice) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_engineKey, choice.name);
  }

  static Future<String> url() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_urlKey) ?? '';
  }

  static Future<void> setUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    var u = url.trim();
    if (u.isNotEmpty && !u.startsWith('http')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    await prefs.setString(_urlKey, u);
  }

  static Future<bool> hasToken() async => (await _storage.read(key: _tokenKey) ?? '').isNotEmpty;

  static Future<void> setToken(String token) =>
      _storage.write(key: _tokenKey, value: token.replaceAll(RegExp(r'\s'), ''));

  static Future<String?> selectedModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_modelKey);
  }

  static Future<void> selectModel(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelKey, id);
  }

  // ── calls ───────────────────────────────────────────────────────────

  static Future<Dio> _dio({Duration receive = const Duration(seconds: 30)}) async {
    final base = await url();
    final token = await _storage.read(key: _tokenKey) ?? '';
    if (base.isEmpty || token.isEmpty) {
      throw PcImageException(
        'The office PC isn\'t set up yet. Open Settings → Image engine and enter its address and token.',
        setup: true,
      );
    }
    return Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: receive,
      headers: {'Authorization': 'Bearer $token'},
      validateStatus: (_) => true,
    ));
  }

  static PcImageException _fail(Response<dynamic> r) {
    final data = r.data;
    final msg = data is Map ? data['error']?.toString() : null;
    if (r.statusCode == 401) {
      return PcImageException('The office PC didn\'t accept the token. Check it in Settings → Image engine.',
          setup: true);
    }
    if (r.statusCode == 530 || r.statusCode == 502) {
      return PcImageException('The office PC isn\'t reachable. Is it switched on?');
    }
    return PcImageException(msg ?? 'The office PC answered with an error (${r.statusCode}).');
  }

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.connectionError) {
        throw PcImageException('Can\'t reach the office PC. Check your internet, and that the PC is on.');
      }
      throw PcImageException('The office PC stopped answering. Try again.');
    }
  }

  static Future<PcStatus> status() => _guard(() async {
        final r = await (await _dio()).get<dynamic>('/health');
        if (r.statusCode != 200 || r.data is! Map) throw _fail(r);
        final d = r.data as Map;
        return PcStatus(
          gpu: d['gpu']?.toString() ?? '?',
          vramGb: (d['vram_gb'] as num?)?.toDouble() ?? 0,
          queue: (d['queue'] as num?)?.toInt() ?? 0,
        );
      });

  static Future<List<PcImageModel>> models() => _guard(() async {
        final r = await (await _dio()).get<dynamic>('/models');
        if (r.statusCode != 200 || r.data is! List) throw _fail(r);
        return (r.data as List).whereType<Map>().map((m) => PcImageModel.fromJson(m.cast<String, dynamic>())).toList();
      });

  /// Width and height for an aspect ratio like "16:9" at about [size]² pixels.
  static (int, int) _dims(String aspectRatio, int size) {
    final parts = aspectRatio.split(':');
    final a = double.tryParse(parts.first) ?? 1;
    final b = parts.length > 1 ? (double.tryParse(parts[1]) ?? 1) : 1;
    final ratio = (a / b).clamp(0.5, 2.0);
    final area = size * size;
    int snap(double v) => ((v / 64).round() * 64).clamp(512, 1536).toInt();
    final w = snap(sqrt(area * ratio));
    final h = snap(sqrt(area / ratio));
    return (w, h);
  }

  /// Makes a picture on the PC. [onProgress] gets a 0–1 guess plus a short state
  /// ("queued, 2 ahead", "drawing").
  static Future<File> generate({
    required String prompt,
    String aspectRatio = '1:1',
    void Function(double progress, String state)? onProgress,
  }) =>
      _guard(() async {
        final dio = await _dio(receive: const Duration(seconds: 60));
        final model = await selectedModel();
        final (w, h) = _dims(aspectRatio, 1024);
        final start = await dio.post<dynamic>('/generate', data: {
          'prompt': prompt,
          if (model != null) 'model': model,
          'width': w,
          'height': h,
        });
        if (start.statusCode != 200 || start.data is! Map) throw _fail(start);
        final id = (start.data as Map)['id'].toString();

        final watch = Stopwatch()..start();
        var misses = 0;
        while (watch.elapsed < const Duration(minutes: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          final Response<dynamic> r;
          try {
            r = await dio.get<dynamic>('/result/$id', options: Options(responseType: ResponseType.bytes));
          } on DioException {
            // One dropped poll on mobile data is normal; keep trying a little.
            if (++misses >= 5) rethrow;
            continue;
          }
          misses = 0;
          if (r.statusCode == 200) return _save(Uint8List.fromList(r.data as List<int>));
          final body = _decode(r.data);
          if (r.statusCode == 202) {
            final pos = (body['position'] as num?)?.toInt();
            onProgress?.call(
              pos == null ? 0.5 : 0.1,
              pos == null ? 'drawing on the office PC' : 'waiting for the office PC ($pos ahead)',
            );
            continue;
          }
          throw PcImageException(body['error']?.toString() ?? 'The office PC answered with an error (${r.statusCode}).');
        }
        throw PcImageException('The office PC took more than 5 minutes. Try again, or switch to the phone engine.');
      });

  static Map<String, dynamic> _decode(dynamic data) {
    try {
      final v = jsonDecode(utf8.decode(data as List<int>));
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<File> _save(Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File('${dir.path}/pc_gen_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
