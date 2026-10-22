import 'package:flutter/material.dart';
import 'package:pocketstrike/app/theme/glass_tokens.dart';
import 'package:pocketstrike/features/local_models/data/local_dream_bridge.dart';
import 'package:pocketstrike/shared/widgets/app_icons.dart';

/// Pick which Local Dream model makes PocketStrike's pictures, and see whether
/// it is loaded. The models live in Download/LocalDream, shared with Local Dream.
class ImageModelSheet extends StatefulWidget {
  const ImageModelSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ImageModelSheet(),
    );
  }

  @override
  State<ImageModelSheet> createState() => _ImageModelSheetState();
}

class _ImageModelSheetState extends State<ImageModelSheet> with WidgetsBindingObserver {
  bool _loading = true;
  bool _bundled = false;
  bool _access = false;
  List<ImageModel> _models = const [];
  String? _selected;
  Map<dynamic, dynamic> _status = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the All-files-access setting or from Local Dream: look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final bundled = await LocalDreamBridge.isBundled();
    final access = bundled && await LocalDreamBridge.hasFilesAccess();
    final models = access ? await LocalDreamBridge.models() : const <ImageModel>[];
    final selected = await LocalDreamBridge.selectedModelId();
    final status = await LocalDreamBridge.status();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _bundled = bundled;
      _access = access;
      _models = models;
      _selected = models.any((m) => m.id == selected) ? selected : (models.isEmpty ? null : models.first.id);
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: tokens.textSecondary, height: 1.4);

    final loadedId = _status['running'] == true ? _status['model'] as String? : null;
    final loadedName = _models.where((m) => m.id == loadedId).map((m) => m.name).firstOrNull;

    final children = <Widget>[
      Row(
        children: [
          Icon(AppIcons.image, color: tokens.accent, size: 20),
          const SizedBox(width: 8),
          Text('Image model', style: theme.textTheme.titleMedium?.copyWith(fontSize: 16)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
        ],
      ),
      Text('Pictures are made on this phone\'s NPU. Nothing is sent online.', style: muted),
      const SizedBox(height: 12),
    ];

    if (_loading) {
      children.add(const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())));
    } else if (!_bundled) {
      children.add(Text(
        'This build has no image engine of its own: pictures come from the Local Dream app, '
        'with whatever model is open in it.',
        style: theme.textTheme.bodyMedium,
      ));
    } else if (!_access) {
      children.addAll([
        Text(
          'PocketStrike uses the models Local Dream downloaded. To read them in Download/LocalDream it '
          'needs All files access.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: LocalDreamBridge.openFilesAccessSettings, child: const Text('Allow All files access')),
      ]);
    } else if (_models.isEmpty) {
      children.addAll([
        Text(
          'No Local Dream models in Download/LocalDream yet.\n\n'
          '1. Open Local Dream\n'
          '2. ⋮ → Settings → Model storage → Downloads\n'
          '3. Come back here',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: LocalDreamBridge.open, child: const Text('Open Local Dream')),
      ]);
    } else {
      for (final m in _models) {
        final details = [
          '${m.size}×${m.size}',
          if (m.steps != null) '${m.steps} steps',
          if (m.id == loadedId) 'loaded',
        ].join(' · ');
        children.add(RadioListTile<String>(
          value: m.id,
          groupValue: _selected,
          contentPadding: EdgeInsets.zero,
          title: Text(m.name),
          subtitle: Text(details, style: muted),
          onChanged: (id) async {
            if (id == null) return;
            setState(() => _selected = id);
            await LocalDreamBridge.selectModel(id);
            await _refresh();
          },
        ));
      }
      children.addAll([
        const SizedBox(height: 4),
        Text(
          loadedName != null
              ? '$loadedName is loaded and ready.'
              : 'The model loads with your first picture (about half a minute).',
          style: muted,
        ),
        if (loadedName != null) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await LocalDreamBridge.stopEngine();
              await _refresh();
            },
            child: const Text('Unload (free memory)'),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Don\'t keep a model open in Local Dream at the same time: two big models can run the phone out of memory.',
          style: muted,
        ),
      ]);
    }

    children.addAll([
      const SizedBox(height: 16),
      Text(
        'Engine: Local Dream 2.8.1 by xororz (github.com/xororz/local-dream), CC BY-NC 4.0.',
        style: muted?.copyWith(fontSize: 11),
      ),
    ]);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(tokens.radiusLg)),
        border: Border(top: BorderSide(color: tokens.glassBorder, width: 0.8)),
      ),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
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
