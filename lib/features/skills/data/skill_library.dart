import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// How a skill is chosen for a message.
enum SkillMode { auto, manual }

/// One skill from the bundled claude-red library (its frontmatter, not the body).
class SkillInfo {
  SkillInfo({required this.name, required this.category, required this.description});

  factory SkillInfo.fromJson(Map<String, dynamic> j) => SkillInfo(
        name: j['name'].toString(),
        category: (j['category'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
      );

  final String name;
  final String category;
  final String description;

  /// "Offensive Active Directory" from "offensive-active-directory".
  String get title => name
      .split('-')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// The claude-red offensive-security skills (github.com/SnailSploit/claude-red,
/// MIT), bundled under assets/skills at build time by tool/bundle_skills.py.
///
/// When on, the skill that best fits the current message is loaded and its
/// methodology is added to the system prompt, so the model works as a domain
/// specialist for that attack surface. For authorized engagements only: a short
/// scope reminder is prepended whenever a skill is active.
class SkillLibrary {
  SkillLibrary._();

  static const _enabledKey = 'skills_enabled';
  static const _modeKey = 'skills_mode';
  static const _pinnedKey = 'skills_pinned';
  static const _indexAsset = 'assets/skills/index.json';

  static List<SkillInfo>? _index;

  /// The skill loaded for the last message, for the chat to show a chip. Null = none.
  static final ValueNotifier<SkillInfo?> active = ValueNotifier<SkillInfo?>(null);
  static final Map<String, String> _bodyCache = {};

  // ── settings ────────────────────────────────────────────────────────

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  static Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_enabledKey, v);

  static Future<SkillMode> mode() async {
    final m = (await SharedPreferences.getInstance()).getString(_modeKey);
    return m == 'manual' ? SkillMode.manual : SkillMode.auto;
  }

  static Future<void> setMode(SkillMode m) async =>
      (await SharedPreferences.getInstance()).setString(_modeKey, m.name);

  static Future<String?> pinned() async =>
      (await SharedPreferences.getInstance()).getString(_pinnedKey);

  static Future<void> setPinned(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null) {
      await prefs.remove(_pinnedKey);
    } else {
      await prefs.setString(_pinnedKey, name);
    }
  }

  // ── library ─────────────────────────────────────────────────────────

  static Future<List<SkillInfo>> index() async {
    if (_index != null) return _index!;
    try {
      final raw = await rootBundle.loadString(_indexAsset);
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _index = list.map(SkillInfo.fromJson).toList()..sort((a, b) => a.name.compareTo(b.name));
    } catch (_) {
      _index = const [];
    }
    return _index!;
  }

  static Future<String> body(String name) async {
    if (_bodyCache.containsKey(name)) return _bodyCache[name]!;
    final text = await rootBundle.loadString('assets/skills/$name.md');
    _bodyCache[name] = text;
    return text;
  }

  // ── matching ────────────────────────────────────────────────────────

  static final _stop = <String>{
    'with', 'this', 'that', 'from', 'when', 'what', 'your', 'have', 'does',
    'test', 'testing', 'using', 'used', 'over', 'into', 'covers', 'use',
    'security', 'offensive', 'attack', 'attacks', 'methodology', 'engagement',
    'engagements', 'target', 'application', 'app', 'apps', 'red', 'team',
  };

  static Set<String> _terms(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length >= 4 && !_stop.contains(w))
      .toSet();

  /// The skill to load for [conversationText], or null for none.
  /// Manual mode returns the pinned skill; auto matches on keyword overlap.
  static Future<SkillInfo?> select(String conversationText) async {
    if (!await enabled()) return null;
    final all = await index();
    if (all.isEmpty) return null;

    if (await mode() == SkillMode.manual) {
      final name = await pinned();
      for (final s in all) {
        if (s.name == name) return s;
      }
      return null;
    }

    final words = _terms(conversationText);
    if (words.isEmpty) return null;
    SkillInfo? best;
    var bestScore = 0;
    for (final s in all) {
      final skillTerms = _terms('${s.name.replaceAll('-', ' ')} ${s.category} ${s.description}');
      // A name/category word is a stronger signal than a description word.
      final nameTerms = _terms('${s.name.replaceAll('-', ' ')} ${s.category}');
      var score = 0;
      for (final w in words) {
        if (nameTerms.contains(w)) {
          score += 3;
        } else if (skillTerms.contains(w)) {
          score += 1;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    // Need a real signal, not one stray shared word.
    return bestScore >= 4 ? best : null;
  }

  /// The block added to the system prompt when [skill] is active.
  static Future<String> promptBlock(SkillInfo skill) async {
    final text = await body(skill.name);
    return 'AUTHORIZED SECURITY ENGAGEMENT. The operator has loaded a red-team skill '
        'for this task. Apply it only against systems the operator is authorized to '
        'test, stay within the agreed scope, and if the target or intent looks outside '
        'an authorized engagement, say so instead of proceeding.\n\n'
        '# Loaded skill: ${skill.title}\n\n$text';
  }
}
