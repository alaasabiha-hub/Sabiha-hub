import 'app_config.dart';
import 'dropdown_options.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

String _t(BuildContext c, String ar, String en) =>
    Localizations.localeOf(c).languageCode == 'ar' ? ar : en;
String _egp(dynamic n) {
  final value = num.tryParse('$n');
  return value == null ? '—' : '${value.toStringAsFixed(2)} EGP';
}

String _digits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(ar[i], '$i');
  }
  return s.trim().replaceAll('٫', '.');
}

/// Branch-scoped purchasing operations, backed by authenticated, audited RPCs.
class InventoryPurchasingPanel extends StatefulWidget {
  final SupabaseClient client;
  final String? branchId;
  final VoidCallback onStockChanged;
  final ValueChanged<String> onBranchSelected;
  const InventoryPurchasingPanel({
    super.key,
    required this.client,
    required this.branchId,
    required this.onStockChanged,
    required this.onBranchSelected,
  });
  @override
  State<InventoryPurchasingPanel> createState() =>
      _InventoryPurchasingPanelState();
}

class _InventoryPurchasingPanelState extends State<InventoryPurchasingPanel> {
  Map<String, dynamic>? data;
  bool loading = true, working = false;
  String? error;
  final Map<String, String> requests = {};
  List<Map<String, dynamic>> rows(String k) =>
      List<Map<String, dynamic>>.from(data?[k] ?? []);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant InventoryPurchasingPanel old) {
    super.didUpdateWidget(old);
    if (old.branchId != widget.branchId) load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = Map<String, dynamic>.from(
        await widget.client.rpc(
          'get_inventory_context',
          params: {'p_branch': widget.branchId},
        ),
      );
      if (mounted) setState(() => data = result);
    } catch (_) {
      if (mounted) {
        setState(() {
          data = null;
          error = 'load';
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> supplier() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _SupplierDialog(client: widget.client, branch: data!['branch_id']),
    );
    if (ok == true && mounted) await load();
  }

  Future<void> purchase() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PurchaseDialog(
        client: widget.client,
        branch: data!['branch_id'],
        suppliers: uniqueDropdownRows(
          rows('suppliers').where((s) => s['is_active'] == true),
          'supplier_id',
        ),
        products: uniqueDropdownRows(
          rows(
            'products',
          ).where((p) => p['is_active'] == true && p['stock_quantity'] != null),
          'item_id',
        ),
      ),
    );
    if (ok == true && mounted) await load();
  }

  Future<void> cancel(Map<String, dynamic> purchase) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _CancelPurchaseDialog(client: widget.client, purchase: purchase),
    );
    if (ok == true && mounted) await load();
  }

  Future<void> count(Map<String, dynamic> product) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _StockCountDialog(client: widget.client, product: product),
    );
    if (ok == true && mounted) {
      widget.onStockChanged();
    }
  }

  Future<void> receive(Map<String, dynamic> purchase) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          _t(c, 'تأكيد استلام المشتريات', 'Confirm purchase receipt'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${purchase['supplier_name']} · ${purchase['invoice_reference']}',
              ),
              for (final l in purchase['lines'] as List? ?? [])
                Text(
                  '${l['name']} × ${l['quantity']} · ${_egp(l['unit_cost'])}',
                ),
              const SizedBox(height: 12),
              Text(
                _t(
                  c,
                  'أكد استلام هذه الكميات فعليًا. سيزيد المخزون، دون تسجيل سداد للمورد.',
                  'Confirm these quantities were physically received. Stock increases; no supplier payment is recorded.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(_t(c, 'إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(_t(c, 'تأكيد الاستلام', 'Confirm receipt')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => working = true);
    final id = '${purchase['purchase_id']}';
    requests.putIfAbsent(id, newOrderRequestId);
    try {
      await widget.client.rpc(
        'receive_inventory_purchase',
        params: {'p_request': requests[id], 'p_purchase': id},
      );
      if (mounted) {
        widget.onStockChanged();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(
                context,
                'تعذر تأكيد الاستلام. حدّث السجل أو أعد المحاولة.',
                'Could not confirm receipt. Refresh the ledger or retry.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Widget heading(String ar, String en) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: Text(
      _t(context, ar, en),
      style: Theme.of(context).textTheme.titleLarge,
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: LinearProgressIndicator(),
      );
    }
    if (error != null) {
      return Column(
        children: [
          Text(
            _t(
              context,
              'تعذر تحميل المشتريات أو حسابك غير مصرح له بإدارتها.',
              'Unable to load purchasing, or your account is not authorized.',
            ),
          ),
          TextButton(
            onPressed: load,
            child: Text(_t(context, 'إعادة المحاولة', 'Retry')),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading(
          'المشتريات والموردون والجرد',
          'Purchases, suppliers & stock counts',
        ),
        if (AppConfig.multiBranchEnabled)
          DropdownButtonFormField<String>(
            key: ValueKey(data!['branch_id']),
            initialValue: validDropdownId(
              '${data!['branch_id']}',
              uniqueDropdownRows(rows('branches'), 'branch_id'),
              'branch_id',
            ),
            isExpanded: true,
            decoration: InputDecoration(
              labelText: _t(context, 'فرع المشتريات', 'Purchasing branch'),
            ),
            items: [
              for (final b in uniqueDropdownRows(rows('branches'), 'branch_id'))
                DropdownMenuItem(
                  value: b['branch_id'] as String,
                  child: Text(
                    '${b[Localizations.localeOf(context).languageCode == 'ar' ? 'name_ar' : 'name_en']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: working
                ? null
                : (v) {
                    if (v != null) widget.onBranchSelected(v);
                  },
          ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: working ? null : supplier,
              icon: const Icon(Icons.person_add_alt),
              label: Text(_t(context, 'إضافة مورد', 'Add supplier')),
            ),
            FilledButton.icon(
              onPressed:
                  working ||
                      rows('suppliers').isEmpty ||
                      !rows('products').any(
                        (p) =>
                            p['is_active'] == true &&
                            p['stock_quantity'] != null,
                      )
                  ? null
                  : purchase,
              icon: const Icon(Icons.add_shopping_cart),
              label: Text(_t(context, 'أمر شراء جديد', 'New purchase order')),
            ),
            IconButton(
              tooltip: _t(context, 'تحديث المشتريات', 'Refresh purchasing'),
              onPressed: working ? null : load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (working) const LinearProgressIndicator(),
        heading('الموردون', 'Suppliers'),
        if (rows('suppliers').isEmpty)
          Text(
            _t(
              context,
              'لم يُسجل مورد لهذا الفرع.',
              'No supplier recorded for this branch.',
            ),
          ),
        for (final s in rows('suppliers'))
          Card(
            child: ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text('${s['name']}'),
              subtitle: Text('${s['phone']}\n${s['tax_reference']}'),
            ),
          ),
        heading('الجرد الفعلي للمنتجات', 'Physical product counts'),
        Text(
          _t(
            context,
            'المنتج غير المعدود يحتاج إلى جرد فعلي قبل استلام المشتريات؛ لا نفترض رصيده صفرًا.',
            'Uncounted products need a physical count before purchase receipt; an opening balance of zero is not assumed.',
          ),
        ),
        for (final p in rows('products'))
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${p['name']}'),
                  Text(
                    '${_t(context, 'المخزون', 'Stock')}: ${p['stock_quantity'] ?? _t(context, 'غير معدود', 'Not counted')}',
                  ),
                  OutlinedButton(
                    onPressed: working ? null : () => count(p),
                    child: Text(_t(context, 'تسجيل الجرد', 'Record count')),
                  ),
                ],
              ),
            ),
          ),
        heading('أوامر الشراء — آخر 100', 'Purchase orders — latest 100'),
        for (final p in rows('purchases'))
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${p['supplier_name']} · ${p['invoice_reference']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${_egp(p['total_cost'])} · ${p['status'] == 'received'
                        ? _t(context, 'مستلم', 'Received')
                        : p['status'] == 'cancelled'
                        ? _t(context, 'ملغى', 'Cancelled')
                        : _t(context, 'بانتظار الاستلام', 'Awaiting receipt')}',
                  ),
                  for (final l in p['lines'] as List? ?? [])
                    Text(
                      '${l['name']} × ${l['quantity']} · ${_egp(l['unit_cost'])}',
                    ),
                  if (p['status'] == 'draft')
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        FilledButton.icon(
                          onPressed: working ? null : () => receive(p),
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: Text(
                            _t(context, 'استلام المشتريات', 'Receive purchase'),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: working ? null : () => cancel(p),
                          child: Text(
                            _t(
                              context,
                              'إلغاء أمر الشراء',
                              'Cancel purchase order',
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (p['cancel_reason'] != null) Text('${p['cancel_reason']}'),
                ],
              ),
            ),
          ),
        heading('سجل المخزون — آخر 100', 'Stock ledger — latest 100'),
        for (final m in rows('movements'))
          Card(
            child: ListTile(
              title: Text(
                '${m['name']} · ${m['before_quantity'] ?? _t(context, 'غير معدود', 'Not counted')} → ${m['after_quantity']}',
              ),
              subtitle: Text(
                '${m['event_type'] == 'count' ? _t(context, 'جرد', 'Count') : _t(context, 'استلام شراء', 'Purchase receipt')} · ${m['created_at']}\n${m['reason']}',
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          _t(
            context,
            'هذه العمليات تسجل المخزون وتكلفة الشراء فقط. سداد الموردين وتكلفة المبيعات والربح المعتمد تُراجع في دفاترها المالية.',
            'These operations record stock and purchase cost only. Supplier payments, cost of sales and approved profit require their financial ledgers.',
          ),
        ),
      ],
    );
  }
}

class _SupplierDialog extends StatefulWidget {
  final SupabaseClient client;
  final String branch;
  const _SupplierDialog({required this.client, required this.branch});
  @override
  State<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<_SupplierDialog> {
  final name = TextEditingController(),
      phone = TextEditingController(),
      tax = TextEditingController();
  final form = GlobalKey<FormState>();
  final request = newOrderRequestId();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    tax.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'save_inventory_supplier',
        params: {
          'p_request': request,
          'p_branch': widget.branch,
          'p_name': name.text.trim(),
          'p_phone': phone.text.trim(),
          'p_tax': tax.text.trim(),
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = _t(
            context,
            'تعذر الحفظ؛ تحقق من الاسم وعدم تسجيله مسبقًا.',
            'Could not save; check the name and existing suppliers.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(_t(context, 'إضافة مورد', 'Add supplier')),
      content: SizedBox(
        width: 480,
        child: Form(
          key: form,
          child: IgnorePointer(
            ignoring: busy,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  maxLength: 120,
                  decoration: InputDecoration(
                    labelText: _t(context, 'اسم المورد', 'Supplier name'),
                  ),
                  validator: (v) => (v?.trim().length ?? 0) < 2
                      ? _t(context, 'أدخل اسم المورد', 'Enter supplier name')
                      : null,
                ),
                TextFormField(
                  controller: phone,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: _t(context, 'هاتف المورد', 'Supplier phone'),
                  ),
                ),
                TextFormField(
                  controller: tax,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: _t(
                      context,
                      'الرقم الضريبي — إن توفر',
                      'Tax reference — if available',
                    ),
                  ),
                ),
                if (error != null) Text(error!),
                if (busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(_t(context, 'إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(_t(context, 'حفظ المورد', 'Save supplier')),
        ),
      ],
    ),
  );
}

class _DraftLine {
  String? item;
  final quantity = TextEditingController(text: '1'),
      cost = TextEditingController();
  void dispose() {
    quantity.dispose();
    cost.dispose();
  }
}

class _PurchaseDialog extends StatefulWidget {
  final SupabaseClient client;
  final String branch;
  final List<Map<String, dynamic>> suppliers, products;
  const _PurchaseDialog({
    required this.client,
    required this.branch,
    required this.suppliers,
    required this.products,
  });
  @override
  State<_PurchaseDialog> createState() => _PurchaseDialogState();
}

class _PurchaseDialogState extends State<_PurchaseDialog> {
  final reference = TextEditingController();
  final form = GlobalKey<FormState>();
  final lines = [_DraftLine()];
  final removed = <_DraftLine>[];
  final request = newOrderRequestId();
  String? supplier, error;
  bool busy = false;
  @override
  void dispose() {
    reference.dispose();
    for (final l in [...lines, ...removed]) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    if (lines.map((l) => l.item).toSet().length != lines.length) {
      setState(
        () => error = _t(
          context,
          'اختر كل منتج مرة واحدة.',
          'Choose each product only once.',
        ),
      );
      return;
    }
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'create_inventory_purchase',
        params: {
          'p_request': request,
          'p_branch': widget.branch,
          'p_supplier': supplier,
          'p_reference': reference.text.trim(),
          'p_lines': [
            for (final l in lines)
              {
                'item_id': l.item,
                'quantity': int.parse(_digits(l.quantity.text)),
                'unit_cost': num.parse(_digits(l.cost.text)),
              },
          ],
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = _t(
            context,
            'تعذر الحفظ. راجع مرجع المورد والمنتجات، أو تحقق من السجل قبل إعادة الإدخال.',
            'Could not save. Check supplier reference/products, or refresh the ledger before re-entering.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget lineNumbers(_DraftLine l) {
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final quantity = TextFormField(
      controller: l.quantity,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: _t(context, 'الكمية', 'Quantity')),
      validator: (v) {
        final n = int.tryParse(_digits(v ?? ''));
        return n == null || n < 1 || n > 100000
            ? _t(context, 'كمية غير صحيحة', 'Invalid quantity')
            : null;
      },
    );
    final cost = TextFormField(
      controller: l.cost,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: _t(context, 'تكلفة الوحدة EGP', 'Unit cost EGP'),
      ),
      validator: (v) {
        final s = _digits(v ?? '');
        final n = num.tryParse(s);
        return !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(s) ||
                n == null ||
                n > 99999999.99
            ? _t(context, 'تكلفة غير صحيحة', 'Invalid cost')
            : null;
      },
    );
    final remove = IconButton(
      tooltip: _t(context, 'حذف السطر', 'Remove line'),
      onPressed: () => setState(() {
        lines.remove(l);
        removed.add(l);
      }),
      icon: const Icon(Icons.remove_circle_outline),
    );
    return narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              quantity,
              const SizedBox(height: 12),
              cost,
              if (lines.length > 1) remove,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: quantity),
              const SizedBox(width: 12),
              Expanded(child: cost),
              if (lines.length > 1) remove,
            ],
          );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(_t(context, 'أمر شراء جديد', 'New purchase order')),
      content: SizedBox(
        width: 520,
        child: Form(
          key: form,
          child: IgnorePointer(
            ignoring: busy,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _t(context, 'المورد', 'Supplier'),
                  ),
                  items: [
                    for (final s in uniqueDropdownRows(
                      widget.suppliers,
                      'supplier_id',
                    ))
                      DropdownMenuItem(
                        value: s['supplier_id'] as String,
                        child: Text(
                          '${s['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => supplier = v,
                  validator: (v) => v == null
                      ? _t(context, 'اختر المورد', 'Choose supplier')
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: reference,
                  maxLength: 120,
                  decoration: InputDecoration(
                    labelText: _t(
                      context,
                      'مرجع فاتورة المورد الفريد',
                      'Unique supplier invoice reference',
                    ),
                  ),
                  validator: (v) => (v?.trim().isEmpty ?? true)
                      ? _t(
                          context,
                          'أدخل مرجع المورد',
                          'Enter supplier reference',
                        )
                      : null,
                ),
                for (final l in lines)
                  Padding(
                    key: ObjectKey(l),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      children: [
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: l.item,
                          decoration: InputDecoration(
                            labelText: _t(context, 'المنتج', 'Product'),
                          ),
                          items: [
                            for (final p in uniqueDropdownRows(
                              widget.products,
                              'item_id',
                            ))
                              DropdownMenuItem(
                                value: p['item_id'] as String,
                                child: Text(
                                  '${p['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => l.item = v,
                          validator: (v) => v == null
                              ? _t(context, 'اختر المنتج', 'Choose product')
                              : null,
                        ),
                        const SizedBox(height: 10),
                        lineNumbers(l),
                      ],
                    ),
                  ),
                if (lines.length < 50)
                  TextButton.icon(
                    onPressed: () => setState(() => lines.add(_DraftLine())),
                    icon: const Icon(Icons.add),
                    label: Text(_t(context, 'إضافة منتج', 'Add product')),
                  ),
                if (error != null) Text(error!),
                if (busy) const LinearProgressIndicator(),
                Text(
                  _t(
                    context,
                    'لا يزيد المخزون عند حفظ الأمر؛ الزيادة بعد تأكيد الاستلام الفعلي.',
                    'Saving the order does not increase stock; physical receipt must be confirmed.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(_t(context, 'إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(_t(context, 'حفظ أمر الشراء', 'Save purchase order')),
        ),
      ],
    ),
  );
}

class _StockCountDialog extends StatefulWidget {
  final SupabaseClient client;
  final Map<String, dynamic> product;
  const _StockCountDialog({required this.client, required this.product});
  @override
  State<_StockCountDialog> createState() => _StockCountDialogState();
}

class _StockCountDialogState extends State<_StockCountDialog> {
  final count = TextEditingController(), reason = TextEditingController();
  final form = GlobalKey<FormState>();
  final request = newOrderRequestId();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    count.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'count_inventory_stock',
        params: {
          'p_request': request,
          'p_item': widget.product['item_id'],
          'p_count': int.parse(_digits(count.text)),
          'p_reason': reason.text.trim(),
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = _t(
            context,
            'تعذر تسجيل الجرد؛ تحقق من الصلاحية وأعد المحاولة.',
            'Could not record count; check permission and retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(
        '${_t(context, 'الجرد الفعلي', 'Physical count')} · ${widget.product['name']}',
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: form,
          child: IgnorePointer(
            ignoring: busy,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: count,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _t(
                      context,
                      'الكمية المعدودة فعليًا',
                      'Actual counted quantity',
                    ),
                  ),
                  validator: (v) {
                    final n = int.tryParse(_digits(v ?? ''));
                    return n == null || n < 0 || n > 10000000
                        ? _t(context, 'أدخل كمية صحيحة', 'Enter valid quantity')
                        : null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: reason,
                  maxLength: 300,
                  decoration: InputDecoration(
                    labelText: _t(
                      context,
                      'سبب الجرد والتعديل',
                      'Count / adjustment reason',
                    ),
                  ),
                  validator: (v) => (v?.trim().length ?? 0) < 5
                      ? _t(context, 'اكتب سببًا واضحًا', 'Enter a clear reason')
                      : null,
                ),
                if (error != null) Text(error!),
                if (busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(_t(context, 'إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(_t(context, 'تأكيد الجرد', 'Confirm count')),
        ),
      ],
    ),
  );
}

class _CancelPurchaseDialog extends StatefulWidget {
  final SupabaseClient client;
  final Map<String, dynamic> purchase;
  const _CancelPurchaseDialog({required this.client, required this.purchase});
  @override
  State<_CancelPurchaseDialog> createState() => _CancelPurchaseDialogState();
}

class _CancelPurchaseDialogState extends State<_CancelPurchaseDialog> {
  final reason = TextEditingController();
  final form = GlobalKey<FormState>();
  final request = newOrderRequestId();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'cancel_inventory_purchase',
        params: {
          'p_request': request,
          'p_purchase': widget.purchase['purchase_id'],
          'p_reason': reason.text.trim(),
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = _t(
            context,
            'تعذر الإلغاء. قد يكون الأمر قد استُلم؛ حدّث السجل.',
            'Could not cancel. The order may already be received; refresh the ledger.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(_t(context, 'إلغاء أمر شراء مسودة', 'Cancel draft purchase')),
      content: SizedBox(
        width: 480,
        child: Form(
          key: form,
          child: IgnorePointer(
            ignoring: busy,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${widget.purchase['invoice_reference']}'),
                TextFormField(
                  controller: reason,
                  maxLength: 300,
                  decoration: InputDecoration(
                    labelText: _t(
                      context,
                      'سبب إلغاء أمر الشراء',
                      'Purchase cancellation reason',
                    ),
                  ),
                  validator: (v) => (v?.trim().length ?? 0) < 5
                      ? _t(context, 'اكتب سببًا واضحًا', 'Enter a clear reason')
                      : null,
                ),
                Text(
                  _t(
                    context,
                    'يبقى الأمر محفوظًا في السجل، ولا يتغير المخزون.',
                    'The order stays in the ledger; stock is unchanged.',
                  ),
                ),
                if (error != null) Text(error!),
                if (busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(_t(context, 'رجوع', 'Back')),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(_t(context, 'تأكيد الإلغاء', 'Confirm cancellation')),
        ),
      ],
    ),
  );
}
