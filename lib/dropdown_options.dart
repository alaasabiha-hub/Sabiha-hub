/// Returns one selectable option per non-empty string identifier.
///
/// RPC joins can repeat a catalogue row (for example, once per branch price).
/// Flutter DropdownButton requires each non-null value to occur exactly once.
/// Keep the first row deterministically and leave source data untouched.
List<Map<String, dynamic>> uniqueDropdownRows(
  Iterable<Map<String, dynamic>> rows,
  String idKey,
) {
  final seen = <String>{};
  return [
    for (final row in rows)
      if (row[idKey] case final String id when id.isNotEmpty && seen.add(id))
        row,
  ];
}

/// Keeps a dropdown selection only when the options contain that ID once.
String? validDropdownId(
  String? selected,
  Iterable<Map<String, dynamic>> options,
  String idKey,
) {
  if (selected == null || selected.isEmpty) return null;
  return options.where((row) => row[idKey] == selected).length == 1
      ? selected
      : null;
}
