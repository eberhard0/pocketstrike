import 'package:flutter/material.dart';

import '../../app/theme/glass_tokens.dart';
import 'glass_button.dart';

/// Friendly empty / zero-state panel with an optional call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    return LayoutBuilder(
      builder: (context, constraints) {
        // On short viewports (folded cover screen with the keyboard up) the
        // panel shrinks and scrolls instead of painting over the input bar.
        final compact = constraints.maxHeight < 360;
        final tiny = constraints.maxHeight < 200;
        return ClipRect(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 20 : 32,
                    vertical: compact ? 12 : 32,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!tiny) ...[
                        Container(
                          width: compact ? 48 : 72,
                          height: compact ? 48 : 72,
                          decoration: BoxDecoration(
                            color: tokens.glassColor,
                            borderRadius:
                                BorderRadius.circular(tokens.radiusLg),
                            border: Border.all(color: tokens.glassBorder),
                          ),
                          child: Icon(icon,
                              size: compact ? 22 : 32, color: tokens.accent),
                        ),
                        SizedBox(height: compact ? 10 : 20),
                      ],
                      Text(
                        title,
                        style: compact
                            ? Theme.of(context).textTheme.titleMedium
                            : Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: tokens.textSecondary,
                            ),
                        textAlign: TextAlign.center,
                        maxLines: compact ? 3 : null,
                        overflow: compact ? TextOverflow.ellipsis : null,
                      ),
                      if (actionLabel != null && onAction != null) ...[
                        SizedBox(height: compact ? 12 : 24),
                        GlassButton(label: actionLabel!, onPressed: onAction),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
