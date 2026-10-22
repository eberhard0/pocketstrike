import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' as llama;
import 'package:pocketstrike/core/models/chat_models.dart';
import 'package:pocketstrike/features/local_models/data/local_dream_bridge.dart';
import 'package:pocketstrike/features/local_models/data/local_model_info.dart';
import 'package:pocketstrike/features/providers/domain/ai_provider.dart';

/// Formatter for prompt formatting across popular local LLM architectures.
class LocalPromptFormatter {
  static String format({
    required List<ChatMessage> messages,
    required String modelNameOrPath,
    String? fallbackSystemPrompt,
  }) {
    final lower = modelNameOrPath.toLowerCase();

    // 1. Separate system prompt and chat conversation turns
    String systemPrompt = '';
    final conversationTurns = <ChatMessage>[];

    for (final m in messages) {
      if (m.role == MessageRole.system) {
        if (m.content.trim().isNotEmpty) {
          systemPrompt = m.content.trim();
        }
      } else {
        if (m.content.trim().isNotEmpty) {
          conversationTurns.add(m);
        }
      }
    }

    if (systemPrompt.isEmpty) {
      systemPrompt = fallbackSystemPrompt ??
          'You are PocketStrike AI, a helpful, intelligent, and direct assistant.';
    }

    // 2. Llama 3 / 3.1 / 3.2 / 3.3
    if (lower.contains('llama-3') ||
        lower.contains('llama3') ||
        lower.contains('llama_3')) {
      final sb = StringBuffer();
      sb.write('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n');
      sb.write(systemPrompt);
      sb.write('<|eot_id|>');

      for (final turn in conversationTurns) {
        final role = turn.role == MessageRole.user ? 'user' : 'assistant';
        sb.write('<|start_header_id|>$role<|end_header_id|>\n\n');
        sb.write(turn.content.trim());
        sb.write('<|eot_id|>');
      }

      sb.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
      return sb.toString();
    }

    // 3. Gemma / Gemma 2 / Gemma 3
    if (lower.contains('gemma')) {
      final sb = StringBuffer();
      sb.write('<bos>');
      var isFirst = true;

      for (final turn in conversationTurns) {
        if (turn.role == MessageRole.user) {
          sb.write('<start_of_turn>user\n');
          if (isFirst && systemPrompt.isNotEmpty) {
            sb.write('$systemPrompt\n\n');
            isFirst = false;
          }
          sb.write('${turn.content.trim()}<end_of_turn>\n');
        } else {
          sb.write('<start_of_turn>model\n${turn.content.trim()}<end_of_turn>\n');
        }
      }

      sb.write('<start_of_turn>model\n');
      return sb.toString();
    }

    // 4. Phi-2 / Phi-3 / Phi-3.5
    if (lower.contains('phi')) {
      final sb = StringBuffer();
      if (systemPrompt.isNotEmpty) {
        sb.write('<|system|>\n$systemPrompt<|end|>\n');
      }
      for (final turn in conversationTurns) {
        final tag = turn.role == MessageRole.user ? 'user' : 'assistant';
        sb.write('<|$tag|>\n${turn.content.trim()}<|end|>\n');
      }
      sb.write('<|assistant|>\n');
      return sb.toString();
    }

    // 5. Mistral / Mixtral
    if (lower.contains('mistral') || lower.contains('mixtral')) {
      final sb = StringBuffer();
      sb.write('<s>');
      var isFirst = true;
      for (final turn in conversationTurns) {
        if (turn.role == MessageRole.user) {
          if (!isFirst) sb.write('</s><s>');
          sb.write('[INST] ');
          if (isFirst && systemPrompt.isNotEmpty) {
            sb.write('$systemPrompt\n\n');
            isFirst = false;
          }
          sb.write('${turn.content.trim()} [/INST]');
        } else {
          sb.write(' ${turn.content.trim()}');
        }
      }
      return sb.toString();
    }

    // 6. Default: ChatML (Qwen, DeepSeek, SmolLM, Yi, and most instruct GGUFs)
    final sb = StringBuffer();
    if (systemPrompt.isNotEmpty) {
      sb.write('<|im_start|>system\n$systemPrompt<|im_end|>\n');
    }
    for (final turn in conversationTurns) {
      final role = turn.role == MessageRole.user ? 'user' : 'assistant';
      sb.write('<|im_start|>$role\n${turn.content.trim()}<|im_end|>\n');
    }
    sb.write('<|im_start|>assistant\n');
    return sb.toString();
  }
}

/// Token streaming filter that strips EOS/EOT delimiters and trailing turn headers.
class LocalStopTokenFilter {
  static const List<String> stopTokens = [
    '<|im_end|>',
    '<|eot_id|>',
    '<end_of_turn>',
    '<|end|>',
    '</s>',
    '<eos>',
    '<|im_start|>',
    '<|start_header_id|>',
    '<start_of_turn>',
    '### User:',
    '### Human:',
    '\nUser:',
    '\nHuman:',
  ];

  String _buffer = '';
  bool _stopped = false;

  bool get isStopped => _stopped;

  String? processToken(String token) {
    if (_stopped) return null;
    _buffer += token;

    for (final stop in stopTokens) {
      final idx = _buffer.indexOf(stop);
      if (idx != -1) {
        _stopped = true;
        final clean = _buffer.substring(0, idx);
        _buffer = '';
        return clean.isNotEmpty ? clean : null;
      }
    }

    for (final stop in stopTokens) {
      for (var len = 1; len < stop.length; len++) {
        if (_buffer.endsWith(stop.substring(0, len))) {
          return null; // Wait for full token to match or pass
        }
      }
    }

    final out = _buffer;
    _buffer = '';
    return out.isNotEmpty ? out : null;
  }

  String? flush() {
    if (_stopped || _buffer.isEmpty) return null;
    final out = _buffer;
    _buffer = '';
    return out;
  }
}

/// Singleton manager for native llama.cpp offline execution on Android.
class LocalLlamaNativeService {
  LocalLlamaNativeService._();
  static final LocalLlamaNativeService instance = LocalLlamaNativeService._();

  llama.LlamaController? _controller;
  String? _loadedModelId;
  String? _loadedModelPath;
  bool _isInitializing = false;

  llama.LlamaController get controller {
    _controller ??= llama.LlamaController();
    return _controller!;
  }

  bool get isAndroid => Platform.isAndroid;
  String? get loadedModelId => _loadedModelId;
  String? get loadedModelPath => _loadedModelPath;

  /// Loads a GGUF model into memory using native llama.cpp runtime.
  Future<bool> loadModel(LocalModelInfo model) async {
    if (!isAndroid) return true; // Graceful fallback for non-Android / tests

    final effectivePath = model.effectiveFilePath;
    final file = File(effectivePath);
    if (!file.existsSync()) {
      if (kDebugMode) {
        print('[LocalLlama] File does not exist: $effectivePath');
      }
      return false;
    }

    // Check if already loaded
    if (_loadedModelPath == effectivePath && _controller != null) {
      try {
        final isLoaded = await _controller!.isModelLoaded();
        if (isLoaded) {
          await clearContext();
          return true;
        }
      } catch (_) {}
    }

    if (_isInitializing) return false;
    _isInitializing = true;

    try {
      // Safely dispose old controller instance
      if (_controller != null) {
        try {
          await _controller!.dispose();
        } catch (_) {}
        _controller = null;
      }

      final newController = llama.LlamaController();
      _controller = newController;

      final safeThreads = min(4, max(1, model.threads));
      final safeContext = min(2048, max(512, model.contextSize));

      try {
        await newController.loadModel(
          modelPath: effectivePath,
          threads: safeThreads,
          contextSize: safeContext,
          gpuLayers: null, // Pure CPU ARM NEON inference is 100% crash-proof
        );
      } catch (loadErr) {
        if (kDebugMode) {
          print(
              '[LocalLlama] First attempt failed ($loadErr), retrying with minimal config');
        }
        await newController.loadModel(
          modelPath: effectivePath,
          threads: 2,
          contextSize: 512,
          gpuLayers: null,
        );
      }

      _loadedModelId = model.id;
      _loadedModelPath = effectivePath;
      await clearContext();

      if (kDebugMode) {
        print(
            '[LocalLlama] Successfully loaded GGUF model: $effectivePath');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('[LocalLlama] Error loading model: $e');
      }
      return false;
    } finally {
      _isInitializing = false;
    }
  }

  /// Clears KV cache to ensure clean generation state.
  Future<void> clearContext() async {
    if (!isAndroid) return;
    try {
      await controller.clearContext();
    } catch (_) {}
  }

  /// Unloads the model and frees RAM memory.
  Future<void> unload() async {
    if (!isAndroid) return;
    if (_controller != null) {
      try {
        await _controller!.dispose();
      } catch (_) {}
      _controller = null;
    }
    _loadedModelId = null;
    _loadedModelPath = null;
  }

  /// Stops in-flight token generation.
  Future<void> stop() async {
    if (!isAndroid) return;
    try {
      await _controller?.stop();
    } catch (_) {}
  }

  /// Streams tokens for prompt.
  Stream<String> generateStream(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double repeatPenalty = 1.1,
  }) {
    if (!isAndroid || _controller == null) {
      return Stream.value('');
    }
    return controller.generate(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      topK: topK,
      repeatPenalty: repeatPenalty,
    );
  }
}

/// 100% Offline Local Model Provider for GGUF LLMs and Local Image Generation.
class LocalAIProvider implements AIProvider {
  LocalAIProvider({this.activeModel});

  final LocalModelInfo? activeModel;

  @override
  String get configId => 'local_model_provider';

  @override
  String get displayName =>
      activeModel != null ? 'Local: ${activeModel!.name}' : 'Local GGUF Engine';

  @override
  bool get supportsTools => true;

  @override
  bool get supportsVision => false;

  @override
  Future<List<String>> listModels() async {
    if (activeModel != null) {
      return [activeModel!.id, activeModel!.name];
    }
    return ['local-gguf-default'];
  }

  @override
  Stream<ChatStreamEvent> streamMessage(ChatRequest request) async* {
    final model = activeModel;
    final lastUserMsg = request.messages
        .where((m) => m.role == MessageRole.user)
        .lastOrNull
        ?.content
        .trim() ??
        '';

    // 1. Image Model or Image Generation Prompt
    final lower = lastUserMsg.toLowerCase();
    final isImagePrompt = model?.type == LocalModelType.imageModel ||
        lower.startsWith('/image') ||
        lower.startsWith('/img') ||
        lower.startsWith('image') ||
        lower.startsWith('photo') ||
        lower.startsWith('picture') ||
        lower.startsWith('wallpaper') ||
        lower.startsWith('generate') ||
        lower.startsWith('create') ||
        lower.startsWith('draw') ||
        lower.startsWith('paint') ||
        lower.startsWith('imagine') ||
        lower.startsWith('render') ||
        lower.contains('generate an image') ||
        lower.contains('generate image') ||
        lower.contains('generate a picture') ||
        lower.contains('generate picture') ||
        lower.contains('draw an image') ||
        lower.contains('draw a picture') ||
        lower.contains('create an image') ||
        lower.contains('create a picture') ||
        lower.contains('make an image') ||
        lower.contains('make a picture') ||
        lower.contains('image of') ||
        lower.contains('picture of') ||
        lower.contains('photo of') ||
        lower.contains('draw ') ||
        lower.contains('paint ') ||
        lower.contains('artwork of');

    if (isImagePrompt) {
      yield* _streamLocalImageGeneration(lastUserMsg, request, model);
      return;
    }

    // 2. Offline Local Chat LLM (GGUF) Native Inference
    yield* _streamLocalChatInference(lastUserMsg, request, model);
  }

  Stream<ChatStreamEvent> _streamLocalChatInference(
    String userPrompt,
    ChatRequest request,
    LocalModelInfo? model,
  ) async* {
    if (model == null) {
      yield const TextDeltaEvent(
        '⚠️ **No Local Model Selected**\n\n'
        'Please select or import a `.gguf` model in **Settings > Local & Offline Models**.',
      );
      yield const StreamDoneEvent();
      return;
    }

    final effectivePath = model.effectiveFilePath;
    final file = File(effectivePath);
    if (!file.existsSync()) {
      yield TextDeltaEvent(
        '⚠️ **No Offline Model Downloaded on Storage**\n\n'
        'You have selected **${model.name}**, but its model weights are not downloaded on device storage yet.\n\n'
        '### 🚀 Quick Start (1-Tap Download):\n'
        '1. Go to **Settings > Local & Offline Models**.\n'
        '2. Tap **"⬇ Download Model"** on **${model.name}** (or lightweight models like **LFM 2.5 230M** or **SmolLM2 135M**).\n'
        '3. Once downloaded, tap **"Load into RAM"** and start chatting 100% offline!',
      );
      yield const StreamDoneEvent();
      return;
    }

    // Ensure model is loaded in memory
    final isLoaded = LocalLlamaNativeService.instance.loadedModelPath == effectivePath;
    if (!isLoaded) {
      final success = await LocalLlamaNativeService.instance.loadModel(
        model.copyWith(filePath: effectivePath),
      );
      if (!success) {
        yield const StreamErrorEvent(
          'Failed to load GGUF model into device memory. Ensure device has enough free RAM.',
        );
        return;
      }
    } else {
      // Clear context before each new query turn to prevent context corruption
      await LocalLlamaNativeService.instance.clearContext();
    }

    // Format prompt using appropriate chat template for the loaded model
    final formattedPrompt = LocalPromptFormatter.format(
      messages: request.messages,
      modelNameOrPath: '${model.name} ${model.filePath}',
      fallbackSystemPrompt: 'You are PocketStrike AI, a helpful, intelligent, and concise assistant.',
    );

    // Bind cancellation token
    request.cancelToken?.whenCancel.then((_) {
      LocalLlamaNativeService.instance.stop();
    });

    final stopwatch = Stopwatch()..start();
    var tokenCount = 0;
    final stopFilter = LocalStopTokenFilter();
    var isFirstYield = true;

    try {
      final tokenStream = LocalLlamaNativeService.instance.generateStream(
        formattedPrompt,
        maxTokens: request.params.maxTokens,
        temperature: request.params.temperature,
        topP: request.params.topP,
        topK: 40,
        repeatPenalty: 1.15,
      );

      await for (final rawToken in tokenStream) {
        if (request.cancelToken?.isCancelled ?? false) break;

        final processed = stopFilter.processToken(rawToken);
        if (stopFilter.isStopped) {
          if (processed != null && processed.isNotEmpty) {
            yield TextDeltaEvent(processed);
            tokenCount++;
          }
          await LocalLlamaNativeService.instance.stop();
          break;
        }

        if (processed != null && processed.isNotEmpty) {
          var cleanToken = processed;
          if (isFirstYield) {
            // Strip any accidental leading role prefix echo or model identifiers
            cleanToken = cleanToken.replaceFirst(
              RegExp(
                r'^(<\|im_start\|>assistant\s*|<\|start_header_id\|>assistant<\|end_header_id\|>\s*|Assistant:\s*|PocketStrike:\s*|AI:\s*|<start_of_turn>model\s*|model\s*\n*)',
                caseSensitive: false,
              ),
              '',
            );
            if (cleanToken.trim().isNotEmpty) {
              isFirstYield = false;
            }
          }

          if (cleanToken.isNotEmpty) {
            yield TextDeltaEvent(cleanToken);
            tokenCount++;
            final curSec = stopwatch.elapsedMilliseconds / 1000.0;
            if (curSec > 0.12 && tokenCount % 2 == 0) {
              yield SpeedMetricsEvent(
                tokensPerSecond: tokenCount / curSec,
                tokenCount: tokenCount,
                latencyMs: stopwatch.elapsedMilliseconds,
              );
            }
          }
        }
      }

      final remaining = stopFilter.flush();
      if (remaining != null && remaining.isNotEmpty) {
        yield TextDeltaEvent(remaining);
        tokenCount++;
      }
    } catch (e) {
      yield StreamErrorEvent('Local GGUF execution error: $e');
      return;
    } finally {
      stopwatch.stop();
    }

    final totalSec = stopwatch.elapsedMilliseconds / 1000.0;
    if (totalSec > 0 && tokenCount > 0) {
      yield SpeedMetricsEvent(
        tokensPerSecond: tokenCount / totalSec,
        tokenCount: tokenCount,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }

    yield UsageEvent(UsageInfo(
      promptTokens: request.messages.fold<int>(0, (acc, m) => acc + (m.content.length ~/ 4)),
      completionTokens: tokenCount,
    ));
    yield const StreamDoneEvent();
  }

  Stream<ChatStreamEvent> _streamLocalImageGeneration(
    String userPrompt,
    ChatRequest request,
    LocalModelInfo? model,
  ) async* {
    var cleanPrompt = userPrompt
        .replaceFirst(RegExp(r'^/image\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^/img\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^generate an image of\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^generate image of\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^generate an image\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^generate image\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^create an image of\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^create image of\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^create image\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^draw an image of\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^draw a\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^draw\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^paint an image of\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^paint\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^imagine\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^make an image of\s*', caseSensitive: false), '')
        .trim();

    if (cleanPrompt.isEmpty) cleanPrompt = userPrompt.trim();
    if (cleanPrompt.isEmpty) cleanPrompt = 'Cyberpunk futuristic skyline';

    final promptDisplay = cleanPrompt;
    final aspectRatio = model?.aspectRatio ?? '1:1';

    final stopwatch = Stopwatch()..start();

    try {
      final imageFile = await synthesizeImageDirect(
        prompt: promptDisplay,
        aspectRatio: aspectRatio,
      );
      stopwatch.stop();

      yield TextDeltaEvent('Here is your image:\n\n![Generated Image](file://${imageFile.path})');
      yield const UsageEvent(UsageInfo(promptTokens: 24, completionTokens: 120));
      yield const StreamDoneEvent();
    } on LocalDreamException catch (e) {
      stopwatch.stop();
      switch (e.action) {
        case ImageEngineAction.allowFilesAccess:
          await LocalDreamBridge.openFilesAccessSettings();
          yield TextDeltaEvent('🎨 ${e.message}');
          yield const StreamDoneEvent();
        case ImageEngineAction.openLocalDream:
          final opened = await LocalDreamBridge.open();
          yield TextDeltaEvent(opened
              ? '🎨 ${e.message}'
              : '🎨 Images use **Local Dream**\'s models, and Local Dream isn\'t installed. Get it from '
                  'github.com/xororz/local-dream/releases, download a model in it (for example Illustrious v16 DMD2), '
                  'move its models to Download/LocalDream (⋮ → Settings → Model storage → Downloads), then send your prompt again.');
          yield const StreamDoneEvent();
        case ImageEngineAction.none:
          yield StreamErrorEvent(e.message);
      }
    } catch (e) {
      stopwatch.stop();
      yield StreamErrorEvent('Could not make the image: $e');
    }
  }

  /// Makes a picture from a prompt (used by chat and the agent's image tool).
  /// It runs in Local Dream on this phone's NPU; see [LocalDreamBridge].
  static Future<File> synthesizeImageDirect({
    required String prompt,
    String aspectRatio = '1:1',
    void Function(int step, int total)? onProgress,
  }) =>
      LocalDreamBridge.generate(prompt: prompt, aspectRatio: aspectRatio, onProgress: onProgress);
}
