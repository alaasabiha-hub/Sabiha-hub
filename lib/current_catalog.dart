/// Public visibility only. Historical records and their financial snapshots stay intact.
bool isCurrentService(Map<String, dynamic> item) => !RegExp(
  r'ceramic|سيراميك|paint\s*protect|حماية\s*الطلاء|\bppf\b',
  caseSensitive: false,
).hasMatch('${item['name'] ?? ''} ${item['name_en'] ?? ''}');

String normalizedNumericInput(String value) {
  const digits = '٠١٢٣٤٥٦٧٨٩';
  return value
      .trim()
      .split('')
      .map((c) {
        final i = digits.indexOf(c);
        return i < 0 ? c : '$i';
      })
      .join()
      .replaceAll('٫', '.');
}
