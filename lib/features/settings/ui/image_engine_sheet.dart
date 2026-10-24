import 'package:flutter/material.dart';
import 'package:pocketstrike/app/theme/glass_tokens.dart';
import 'package:pocketstrike/features/local_models/data/pc_image_engine.dart';
import 'package:pocketstrike/shared/widgets/app_icons.dart';

/// Pick where pictures are made: Local Dream on this phone, or the office
/// PC's graphics card (address + token, then a model the PC offers).
class ImageEngineSheet extends StatefulWidget {
  const ImageEngineSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ImageEngineSheet(),
    );
  }

  @override
  State<ImageEngineSheet> createState() => _ImageEngineSheetState();
}

class _ImageEngineSheetState extends State<ImageEngineSheet> {
  ImageEngineChoice _engine = ImageEngineChoice.phone;
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _hasToken = false;
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;
  List<PcImageModel> _models = const [];
  String? _model;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final engine = await PcImageEngine.engine();
    final url = await PcImageEngine.url();
    final hasToken = await PcImageEngine.hasToken();
    final model = await PcImageEngine.selectedModel();
    if (!mounted) return;
    setState(() {
      _engine = engine;
      _url.text = url;
      _hasToken = hasToken;
      _model = model;
    });
    if (engine == ImageEngineChoice.pc && url.isNotEmpty && hasToken) await _test();
  }

  Future<void> _setEngine(ImageEngineChoice? choice) async {
    if (choice == null) return;
    await PcImageEngine.setEngine(choice);
    setState(() => _engine = choice);
    if (choice == ImageEngineChoice.pc && _url.text.isNotEmpty && _hasToken && _models.isEmpty) await _test();
  }

  Future<void> _saveAndTest() async {
    await PcImageEngine.setUrl(_url.text);
    if (_token.text.trim().isNotEmpty) {
      await PcImageEngine.setToken(_token.text);
      _token.clear();
    }
    final url = await PcImageEngine.url();
    final hasToken = await PcImageEngine.hasToken();
    if (!mounted) return;
    setState(() {
      _url.text = url;
      _hasToken = hasToken;
    });
    await _test();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = 'Connecting…';
      _statusIsError = false;
    });
    try {
      final s = await PcImageEngine.status();
      final models = await PcImageEngine.models();
      var model = _model;
      if (models.isNotEmpty && !models.any((m) => m.id == model)) {
        model = models.first.id;
        await PcImageEngine.selectModel(model);
      }
      if (!mounted) return;
      setState(() {
        _status = 'Connected: ${s.gpu} · ${s.vramGb.toStringAsFixed(0)} GB'
            '${s.queue > 0 ? ' · ${s.queue} in queue' : ''}'
            '${models.isEmpty ? '\nNo image models installed on the PC yet.' : ''}';
        _models = models;
        _model = model;
      });
    } on PcImageException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.message;
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: tokens.textSecondary, height: 1.4);

    final children = <Widget>[
      Row(
        children: [
          Icon(AppIcons.image, color: tokens.accent, size: 20),
          const SizedBox(width: 8),
          Text('Image engine', style: theme.textTheme.titleMedium?.copyWith(fontSize: 16)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
        ],
      ),
      RadioListTile<ImageEngineChoice>(
        value: ImageEngineChoice.phone,
        groupValue: _engine,
        onChanged: _setEngine,
        contentPadding: EdgeInsets.zero,
        title: const Text('This phone'),
        subtitle: Text('Local Dream on the phone\'s AI chip. Offline, free; open a model in Local Dream first.',
            style: muted),
      ),
      RadioListTile<ImageEngineChoice>(
        value: ImageEngineChoice.pc,
        groupValue: _engine,
        onChanged: _setEngine,
        contentPadding: EdgeInsets.zero,
        title: const Text('Office PC'),
        subtitle: Text('The PC\'s NVIDIA card: bigger models and better pictures. Needs internet and the PC switched on.',
            style: muted),
      ),
    ];

    if (_engine == ImageEngineChoice.pc) {
      children.addAll([
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'PC address', hintText: 'https://draw.iameberhard.com'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _token,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Token',
            hintText: _hasToken ? 'Saved. Paste a new one to replace it' : 'Paste the token from the PC',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _saveAndTest,
          child: Text(_busy ? 'Connecting…' : 'Save and test'),
        ),
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(
            _status!,
            style: muted?.copyWith(color: _statusIsError ? theme.colorScheme.error : null),
          ),
        ],
        if (_models.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Model', style: theme.textTheme.titleSmall),
          for (final m in _models)
            RadioListTile<String>(
              value: m.id,
              groupValue: _model,
              contentPadding: EdgeInsets.zero,
              title: Text(m.name),
              subtitle: Text('${m.size}×${m.size}', style: muted),
              onChanged: (id) async {
                if (id == null) return;
                await PcImageEngine.selectModel(id);
                setState(() => _model = id);
              },
            ),
        ],
      ]);
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(tokens.radiusLg)),
        border: Border(top: BorderSide(color: tokens.glassBorder, width: 0.8)),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewPadding.bottom + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
