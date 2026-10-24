import 'package:flutter/material.dart';
import 'package:pocketstrike/app/theme/glass_tokens.dart';
import 'package:pocketstrike/features/skills/data/skill_library.dart';
import 'package:pocketstrike/shared/widgets/app_icons.dart';

/// Turn the claude-red red-team skills on, choose auto-match or a pinned skill,
/// and browse the library by category.
class SkillsSheet extends StatefulWidget {
  const SkillsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SkillsSheet(),
    );
  }

  @override
  State<SkillsSheet> createState() => _SkillsSheetState();
}

class _SkillsSheetState extends State<SkillsSheet> {
  bool _loading = true;
  bool _enabled = false;
  SkillMode _mode = SkillMode.auto;
  String? _pinned;
  List<SkillInfo> _skills = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await SkillLibrary.enabled();
    final mode = await SkillLibrary.mode();
    final pinned = await SkillLibrary.pinned();
    final skills = await SkillLibrary.index();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _enabled = enabled;
      _mode = mode;
      _pinned = pinned;
      _skills = skills;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: tokens.textSecondary, height: 1.4);

    final filtered = _query.isEmpty
        ? _skills
        : _skills
            .where((s) =>
                s.name.contains(_query) ||
                s.category.contains(_query) ||
                s.description.toLowerCase().contains(_query))
            .toList();

    final children = <Widget>[
      Row(
        children: [
          Icon(AppIcons.shieldCheck, color: tokens.accent, size: 20),
          const SizedBox(width: 8),
          Text('Red team skills', style: theme.textTheme.titleMedium?.copyWith(fontSize: 16)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
        ],
      ),
      Text(
        '${_skills.length} offensive-security skills (claude-red, MIT). The one that fits your '
        'message primes the model for that attack surface. For authorized engagements only.',
        style: muted,
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        value: _enabled,
        contentPadding: EdgeInsets.zero,
        title: const Text('Use red team skills'),
        onChanged: (v) async {
          await SkillLibrary.setEnabled(v);
          setState(() => _enabled = v);
        },
      ),
    ];

    if (_enabled) {
      children.addAll([
        SegmentedButton<SkillMode>(
          segments: const [
            ButtonSegment(value: SkillMode.auto, label: Text('Auto-match'), icon: Icon(Icons.auto_awesome, size: 16)),
            ButtonSegment(value: SkillMode.manual, label: Text('Pin one'), icon: Icon(Icons.push_pin, size: 16)),
          ],
          selected: {_mode},
          onSelectionChanged: (s) async {
            await SkillLibrary.setMode(s.first);
            setState(() => _mode = s.first);
          },
        ),
        const SizedBox(height: 6),
        Text(
          _mode == SkillMode.auto
              ? 'The best-fitting skill loads automatically for each message.'
              : 'Only the skill you pin below is used, for every message.',
          style: muted,
        ),
        const SizedBox(height: 10),
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Search skills (e.g. jwt, kerberos, s3)',
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: filtered.length,
              itemBuilder: (_, i) {
                final s = filtered[i];
                final pinnedHere = _mode == SkillMode.manual && _pinned == s.name;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(s.title, style: theme.textTheme.bodyMedium),
                  subtitle: Text(
                    '${s.category} · ${s.description}',
                    style: muted,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _mode == SkillMode.manual
                      ? Icon(
                          pinnedHere ? Icons.push_pin : Icons.push_pin_outlined,
                          size: 18,
                          color: pinnedHere ? tokens.accent : tokens.textSecondary,
                        )
                      : null,
                  onTap: _mode == SkillMode.manual
                      ? () async {
                          final next = pinnedHere ? null : s.name;
                          await SkillLibrary.setPinned(next);
                          setState(() => _pinned = next);
                        }
                      : null,
                );
              },
            ),
          ),
      ]);
    }

    children.addAll([
      const SizedBox(height: 10),
      Text(
        'Skills by SnailSploit & Mixbanana — github.com/SnailSploit/claude-red (MIT).',
        style: muted?.copyWith(fontSize: 11),
      ),
    ]);

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
