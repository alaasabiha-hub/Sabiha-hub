import 'package:flutter/material.dart';

/// Uses only the authoritative catalogue supplied by the existing POS gateway.
class CashierCatalogButtons extends StatefulWidget {
  const CashierCatalogButtons({
    super.key,
    required this.items,
    required this.arabic,
    required this.enabled,
    required this.onAdd,
    this.vehicleClassName,
    this.categories = const [],
  });
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> categories;
  final bool arabic, enabled;
  final String? vehicleClassName;
  final ValueChanged<Map<String, dynamic>> onAdd;
  @override
  State<CashierCatalogButtons> createState() => _CashierCatalogButtonsState();
}

class _CashierCatalogButtonsState extends State<CashierCatalogButtons> {
  String type = 'all';
  String? category;
  bool featuredOnly = false;
  String t(String ar, String en) => widget.arabic ? ar : en;
  @override
  Widget build(BuildContext context) {
    final visible =
        widget.items
            .where(
              (item) =>
                  (type == 'all' || item['item_type'] == type) &&
                  (category == null ||
                      !widget.categories.any(
                        (c) => c['category_id'] == category,
                      ) ||
                      item['pos_category_id'] == category) &&
                  (!featuredOnly || item['pos_featured'] == true),
            )
            .toList()
          ..sort((a, b) {
            final order = ((a['pos_sort_order'] as num?) ?? 0).compareTo(
              (b['pos_sort_order'] as num?) ?? 0,
            );
            return order != 0
                ? order
                : '${a['item_id']}'.compareTo('${b['item_id']}');
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tab in [
              ('all', t('الكل', 'All')),
              ('service', t('الخدمات', 'Services')),
              ('product', t('المنتجات', 'Products')),
            ])
              ChoiceChip(
                key: ValueKey('pos_type_${tab.$1}'),
                label: Text(
                  tab.$2,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                selected: type == tab.$1,
                onSelected: widget.enabled
                    ? (_) => setState(() => type = tab.$1)
                    : null,
              ),
          ],
        ),
        if (widget.categories.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('pos_category_all'),
                label: Text(t('كل التصنيفات', 'All categories')),
                selected: category == null,
                onSelected: widget.enabled
                    ? (_) => setState(() => category = null)
                    : null,
              ),
              for (final c in widget.categories)
                ChoiceChip(
                  key: ValueKey('pos_category_${c['category_id']}'),
                  label: Text('${widget.arabic ? c['name_ar'] : c['name_en']}'),
                  selected: category == c['category_id'],
                  onSelected: widget.enabled
                      ? (_) => setState(
                          () => category = c['category_id'] as String,
                        )
                      : null,
                ),
            ],
          ),
        if (widget.items.any((item) => item['pos_featured'] == true))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilterChip(
              key: const ValueKey('pos_featured'),
              label: Text(t('المفضلة', 'Favorites')),
              selected: featuredOnly,
              onSelected: widget.enabled
                  ? (v) => setState(() => featuredOnly = v)
                  : null,
            ),
          ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          Text(t('لا توجد بنود في هذه القائمة.', 'No items in this list.')),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                constraints.maxWidth >= 340 && constraints.maxWidth < 480
                ? 2
                : (constraints.maxWidth / 210).floor().clamp(1, 6);
            final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final item in visible)
                  SizedBox(
                    width: width,
                    child: Tooltip(
                      message: t('إضافة بند', 'Add line'),
                      child: OutlinedButton(
                        key: ValueKey('pos_item_${item['item_id']}'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 180),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          backgroundColor: const Color(0xff071a36),
                          textStyle: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          padding: const EdgeInsets.all(14),
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xffc5cbd5)),
                        ),
                        onPressed:
                            widget.enabled &&
                                (item['item_type'] != 'service' ||
                                    item['vehicle_price_verified'] == true &&
                                        item['vehicle_price_available'] ==
                                            true) &&
                                item['price'] is num &&
                                (item['price'] as num).isFinite
                            ? () => widget.onAdd(item)
                            : null,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item['image_display_url'] is String ||
                                item['image_url'] is String &&
                                    Uri.tryParse(item['image_url'])?.scheme ==
                                        'https')
                              Image.network(
                                (item['image_display_url'] ?? item['image_url'])
                                    as String,
                                height: 78,
                                width: 130,
                                fit: BoxFit.contain,
                                errorBuilder: (_, error, stack) => Icon(
                                  item['item_type'] == 'service'
                                      ? Icons.local_car_wash
                                      : Icons.shopping_bag_outlined,
                                  color: const Color(0xffc5cbd5),
                                  size: 34,
                                ),
                              )
                            else
                              Icon(
                                item['item_type'] == 'service'
                                    ? Icons.local_car_wash
                                    : Icons.shopping_bag_outlined,
                                color: const Color(0xffc5cbd5),
                                size: 34,
                              ),
                            const SizedBox(height: 8),
                            Text(
                              '${widget.arabic ? item['name'] : item['name_en'] ?? item['name']}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                height: 1.35,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              item['item_type'] == 'service' &&
                                      item['vehicle_price_verified'] != true
                                  ? t(
                                      'اربط سيارة لإظهار سعر فئتها',
                                      'Bind a vehicle to show its class price',
                                    )
                                  : item['item_type'] == 'service' &&
                                        item['vehicle_price_verified'] ==
                                            true &&
                                        item['vehicle_price_available'] != true
                                  ? t(
                                      'لا يوجد سعر لفئة ${widget.vehicleClassName ?? ''}',
                                      'No price set for ${widget.vehicleClassName ?? 'this class'}',
                                    )
                                  : item['price'] is num
                                  ? '${(item['price'] as num).toStringAsFixed(2)} EGP'
                                  : t('السعر غير متاح', 'Price unavailable'),
                              textAlign: TextAlign.center,
                            ),
                            if (item['item_type'] == 'service' &&
                                item['vehicle_price_verified'] == true &&
                                widget.vehicleClassName != null)
                              Text(
                                '${widget.vehicleClassName} · ${t('حسب فئة السيارة', 'vehicle class rate')}',
                                textAlign: TextAlign.center,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
