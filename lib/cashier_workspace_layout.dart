import 'package:flutter/material.dart';

/// Retains the same draft widgets and controllers on every screen size.
class CashierWorkspaceLayout extends StatelessWidget {
  const CashierWorkspaceLayout({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final split = children.indexWhere(
        (w) => w.key == const ValueKey('pos_draft_divider'),
      );
      if (size.maxWidth < 1100 || split < 0) {
        return ListView(padding: const EdgeInsets.all(16), children: children);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 6,
            child: ListView(
              key: const ValueKey('pos_catalog_scroll'),
              padding: const EdgeInsets.all(16),
              children: children.take(split).toList(),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 5,
            child: ListView(
              key: const ValueKey('pos_draft_scroll'),
              padding: const EdgeInsets.all(16),
              children: children.skip(split + 1).toList(),
            ),
          ),
        ],
      );
    },
  );
}
