/// Resolves a price only from the server-provided class price map.
/// It deliberately never falls back to the legacy flat catalogue price.
num? servicePriceForVehicle(
  Map<String, dynamic> service,
  Map<String, dynamic>? vehicle,
) {
  final code = vehicle?['vehicle_class_code'];
  final prices = service['vehicle_prices'];
  if (code is! String || code.isEmpty || prices is! Map) return null;
  final value = prices[code];
  if (value is num && value >= 0 && value.isFinite) return value;
  if (value is String) {
    final parsed = num.tryParse(value);
    if (parsed != null && parsed >= 0 && parsed.isFinite) return parsed;
  }
  return null;
}

String? vehicleClassName(Map<String, dynamic>? vehicle, bool arabic) {
  if (vehicle == null) return null;
  final name =
      vehicle[arabic ? 'vehicle_class_name_ar' : 'vehicle_class_name_en'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  final code = vehicle['vehicle_class_code'];
  return code is String && code.isNotEmpty ? code : null;
}
