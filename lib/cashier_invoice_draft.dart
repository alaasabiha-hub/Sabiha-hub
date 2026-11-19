import 'cashier_workspace_layout.dart';
import 'cashier_open_drafts.dart';
import 'catalog_media.dart';
import 'cashier_catalog_buttons.dart';

// Reviewed drafts and immutable server-issued checkout commands.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cashier_customer_binding.dart';
import 'cashier_checkout.dart';
import 'cashier_shifts.dart';
import 'service_work.dart';
import 'invoices.dart'
    show matchesInitialAuthReplay, InvoiceDocumentsScreen, buildInvoicePdf;
import 'workflow.dart' show newOrderRequestId;

abstract class CashierCartGateway {
  bool get current;
  Stream<void> get changes;
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
}

abstract class CashierCatalogUpdates {
  Stream<void> catalogChanges(String branch);
}

class SupabaseCashierCartGateway
    implements CashierCartGateway, CashierCatalogUpdates {
  SupabaseCashierCartGateway(this.client)
    : session = client.auth.currentSession;
  final SupabaseClient client;
  final Session? session;
  @override
  bool get current =>
      session != null &&
      client.auth.currentSession?.accessToken == session!.accessToken &&
      client.auth.currentUser?.id == session!.user.id;
  @override
  Stream<void> get changes => client.auth.onAuthStateChange
      .where((e) => !matchesInitialAuthReplay(e, session))
      .map((_) {});
  @override
  Stream<void> catalogChanges(String branch) {
    late StreamController<void> events;
    RealtimeChannel? channel;
    events = StreamController<void>(
      onListen: () {
        channel = client
            .channel('cashier-catalog-$branch-${identityHashCode(events)}')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'cashier_catalog_revisions',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'branch_id',
                value: branch,
              ),
              callback: (_) {
                if (!events.isClosed && current) events.add(null);
              },
            )
            .subscribe((status, error) {
              if (!events.isClosed && current) events.add(null);
            });
      },
      onCancel: () async {
        if (channel != null) await client.removeChannel(channel!);
      },
    );
    return events.stream;
  }

  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!current ||
        !const {
          'get_cashier_checkout_state',
          'get_cashier_mixed_points_context',
          'get_cashier_mixed_visits_context',
          'reserve_cashier_mixed_visits',
          'confirm_cashier_mixed_visits_verbal',
          'release_cashier_mixed_visits',
          'issue_cashier_visit_invoice',
          'reserve_cashier_mixed_points',
          'confirm_cashier_mixed_points_verbal',
          'release_cashier_mixed_points',
          'issue_cashier_points_invoice',
          'resolve_cashier_start_time',
          'issue_cashier_invoice',
          'issue_cashier_mixed_invoice',
          'confirm_cashier_cash_payment',
          'confirm_cashier_terminal_payment',
          'confirm_cashier_terminal_refund',
          'confirm_cashier_adjusted_cash',
          'cancel_unpaid_cashier_service',
          'preview_cashier_refund_lines',
          'confirm_cashier_refund',
          'cancel_cashier_service',
          'get_invoice_refund_document',
          'get_cashier_reviewed_context',
          'get_cashier_catalogue_review',
          'get_cashier_vehicle_service_prices',
          'find_cashier_customers',
          'bind_cashier_draft_subject',
          'get_cashier_draft_subject',
          'seal_cashier_loyalty_draft',
          'get_cashier_loyalty_draft_intent',
          'get_cashier_reviewed_draft',
          'list_cashier_open_drafts',
          'save_cashier_reviewed_draft',
        }.contains(name)) {
      throw StateError('Unavailable cashier session');
    }
    final value = await client
        .rpc(name, params: params)
        .timeout(const Duration(seconds: 25));
    if (!current) throw StateError('Session changed');
    final result = Map<String, dynamic>.from(value as Map);
    if (name == 'get_cashier_reviewed_context') {
      final items = List<Map<String, dynamic>>.from(result['items'] ?? []);
      try {
        await enrichCatalogImages(client, items);
      } catch (_) {
        /* Existing local schemas can still display HTTPS images. */
      }
      result['items'] = items;
      final staff = List<Map<String, dynamic>>.from(result['staff'] ?? []);
      try {
        if (staff.isNotEmpty) {
          final photos = await client
              .from('employee_public_profiles')
              .select('user_id,photo_path')
              .inFilter('user_id', staff.map((s) => s['staff_id']).toList())
              .eq('is_published', true)
              .eq('photo_consent', true)
              .not('photo_approved_by', 'is', null);
          await Future.wait(
            photos.map((photo) async {
              if (photo['photo_path'] is! String) return;
              try {
                final url = await client.storage
                    .from('staff-photos')
                    .createSignedUrl(photo['photo_path'], 300);
                for (final s in staff) {
                  if (s['staff_id'] == photo['user_id']) s['photo_url'] = url;
                }
              } catch (_) {
                /* A missing approved photo uses an avatar. */
              }
            }),
          );
        }
      } catch (_) {
        /* Photo availability never changes eligible workers. */
      }
      result['staff'] = staff;
    }
    if (!current) throw StateError('Session changed');
    return result;
  }
}

class CashierInvoiceDraftScreen extends StatefulWidget {
  const CashierInvoiceDraftScreen({
    super.key,
    required this.gateway,
    required this.branch,
    this.initialDraftId,
    this.catalogRefreshInterval = const Duration(seconds: 20),
  });
  final CashierCartGateway gateway;
  final String branch;
  final String? initialDraftId;
  final Duration catalogRefreshInterval;
  @override
  State<CashierInvoiceDraftScreen> createState() =>
      _CashierInvoiceDraftScreenState();
}

class _CashierInvoiceDraftScreenState extends State<CashierInvoiceDraftScreen>
    with WidgetsBindingObserver {
  final search = TextEditingController(),
      discount = TextEditingController(text: '0');
  final cart = <String, Map<String, dynamic>>{};
  final quantities = <String, TextEditingController>{};
  StreamSubscription<void>? subscription, catalogSubscription;
  Timer? catalogPoll;
  bool refreshingCatalog = false, catalogOffline = false;
  String? catalogNotice;
  final catalogPriceChanges = <String, String>{};
  final catalogueOriginalPrices = <String, num>{};
  Map<String, dynamic>? contextData, quote, pending;
  List<Map<String, dynamic>> catalogue = [];
  Map<String, dynamic> classServicePrices = const {};
  String? selectedVehicleClassCode,
      selectedVehicleClassNameAr,
      selectedVehicleClassNameEn;
  String draft = newOrderRequestId(), mode = 'fixed';
  int version = 0, epoch = 0;
  bool busy = false, invalid = false, dirty = true, bindingBusy = false;
  bool checkoutBusy = false, issued = false;
  int bindingRevision = 0;
  String? error;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool get active => mounted && !invalid && widget.gateway.current;
  num? quotedUnitPrice(Map<String, dynamic> item) {
    final lines = quote?['lines'];
    if (quote?['vehicle_pricing_ready'] != true || lines is! List) return null;
    final line = lines
        .cast<Map>()
        .where((x) => x['item_id'] == item['item_id'])
        .firstOrNull;
    final value = line?['unit_price'];
    return value is num && value.isFinite ? value : null;
  }

  num? displayedUnitPrice(Map<String, dynamic> item) =>
      quotedUnitPrice(item) ??
      (item['item_type'] == 'service' ? null : item['price'] as num?);
  bool get canStartNew =>
      active && !busy && !bindingBusy && !checkoutBusy && pending == null;
  bool get editable => canStartNew && !issued && !catalogOffline;
  String money(dynamic n) => n is num ? n.toStringAsFixed(2) : '—';
  String numericInput(String value) => value
      .trim()
      .replaceAll('٫', '.')
      .replaceAllMapped(RegExp(r'[٠-٩۰-۹]'), (m) {
        final c = m[0]!.runes.single;
        return '${c >= 0x6f0 ? c - 0x6f0 : c - 0x660}';
      });
  @override
  void initState() {
    super.initState();
    subscription = widget.gateway.changes.listen((_) => invalidate());
    WidgetsBinding.instance.addObserver(this);
    final gateway = widget.gateway;
    if (gateway is CashierCatalogUpdates) {
      catalogSubscription = (gateway as CashierCatalogUpdates)
          .catalogChanges(widget.branch)
          .listen((_) => unawaited(refreshCatalog()));
    }
    catalogPoll = Timer.periodic(
      widget.catalogRefreshInterval,
      (_) => unawaited(refreshCatalog()),
    );
    unawaited(load(recover: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refreshCatalog());
  }

  void applyCatalogueReview(Map<String, dynamic> review) {
    if (issued || review['needs_review'] != true) return;
    dirty = true;
    for (final change in List<Map<String, dynamic>>.from(
      review['changes'] ?? [],
    )) {
      final id = change['item_id'] as String;
      final previous = change['previous_price'];
      if (previous is num) {
        catalogueOriginalPrices.putIfAbsent(id, () => previous);
      }
      catalogPriceChanges[id] =
          '${ar ? change['name'] : change['name_en'] ?? change['name']}: ${money(catalogueOriginalPrices[id])} → ${money(change['current_price'])} EGP${change['active'] == false ? t(' (غير متاح)', ' (unavailable)') : ''}';
    }
    catalogNotice =
        '${t('تغير الكتالوج. راجع الأسعار وتوفر البنود، ثم أعد حفظ المسودة قبل الإصدار.', 'Catalogue changed. Review prices and item availability, then save the draft again before issuing.')} ${catalogPriceChanges.values.join(' · ')}';
  }

  Future<void> refreshCatalog() async {
    if (!active ||
        refreshingCatalog ||
        busy ||
        pending != null ||
        bindingBusy ||
        checkoutBusy) {
      return;
    }
    refreshingCatalog = true;
    final generation = epoch;
    try {
      final refreshed = <Map<String, dynamic>>[];
      Map<String, dynamic>? data;
      String? after;
      final pages = ((catalogue.length + 99) ~/ 100).clamp(1, 1000000);
      for (var page = 0; page < pages; page++) {
        data = await widget.gateway.call('get_cashier_reviewed_context', {
          'p_branch': widget.branch,
          'p_search': search.text.trim(),
          'p_after': after,
        });
        if (!active || generation != epoch) return;
        if (data['quote_only'] != true || data['can_issue'] != false) {
          throw StateError('Unverified catalogue');
        }
        final items = List<Map<String, dynamic>>.from(data['items']);
        refreshed.addAll(items);
        if (data['has_more'] != true || items.isEmpty) break;
        after = items.last['item_id'] as String;
      }
      if (!active ||
          generation != epoch ||
          data == null ||
          pending != null ||
          bindingBusy ||
          checkoutBusy ||
          busy) {
        return;
      }
      Map<String, dynamic>? review;
      if (!issued &&
          quote != null &&
          data['catalogue_review_supported'] == true) {
        review = await widget.gateway.call('get_cashier_catalogue_review', {
          'p_branch': widget.branch,
          'p_draft': draft,
          'p_version': version,
        });
        if (!active ||
            generation != epoch ||
            pending != null ||
            checkoutBusy ||
            bindingBusy ||
            busy) {
          return;
        }
      }
      final changed =
          jsonEncode([
            catalogue,
            contextData?['pos_categories'],
            contextData?['pos_layout_version'],
          ]) !=
          jsonEncode([
            refreshed,
            data['pos_categories'],
            data['pos_layout_version'],
          ]);
      setState(() {
        final wasOffline = catalogOffline;
        catalogOffline = false;
        if (wasOffline) {
          catalogNotice = catalogPriceChanges.isEmpty
              ? null
              : '${t('تغير الكتالوج. راجع الأسعار وتوفر البنود، ثم أعد حفظ المسودة قبل الإصدار.', 'Catalogue changed. Review prices and item availability, then save the draft again before issuing.')} ${catalogPriceChanges.values.join(' · ')}';
        }
        if (changed && !issued && cart.isNotEmpty) {
          for (final row in cart.values) {
            final updated = refreshed
                .where((i) => i['item_id'] == row['item_id'])
                .firstOrNull;
            if (updated == null) continue;
            final previous = row['price'] ?? row['unit_price'];
            if (previous is num && previous != updated['price']) {
              final id = row['item_id'] as String;
              catalogueOriginalPrices.putIfAbsent(id, () => previous);
              catalogPriceChanges[id] =
                  '${updated['name']}: ${money(catalogueOriginalPrices[id])} → ${money(updated['price'])} EGP';
            }
            for (final key in ['name', 'name_en', 'price', 'image_url']) {
              if (updated.containsKey(key)) row[key] = updated[key];
            }
          }
          dirty = true;
          catalogNotice =
              '${t('تغير الكتالوج. راجع الأسعار وتوفر البنود، ثم أعد حفظ المسودة قبل الإصدار.', 'Catalogue changed. Review prices and item availability, then save the draft again before issuing.')} ${catalogPriceChanges.values.join(' · ')}';
        }
        if (review != null) applyCatalogueReview(review);
        catalogue = refreshed;
        contextData = data;
      });
    } catch (_) {
      if (active && generation == epoch) {
        setState(() {
          catalogOffline = true;
          catalogNotice = t(
            'تعذر تحديث الكتالوج. الإضافة متوقفة حتى إعادة الاتصال والتحقق.',
            'Catalogue sync unavailable. Adding items is paused until reconnection and verification.',
          );
        });
      }
    } finally {
      refreshingCatalog = false;
    }
  }

  void invalidate() {
    if (!mounted) return;
    epoch++;
    for (final c in quantities.values) {
      c.dispose();
    }
    quantities.clear();
    setState(() {
      invalid = true;
      bindingBusy = false;
      checkoutBusy = false;
      issued = false;
      busy = false;
      cart.clear();
      catalogue = [];
      contextData = quote = pending = null;
      discount.clear();
      search.clear();
    });
  }

  @override
  void didUpdateWidget(covariant CashierInvoiceDraftScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.branch != widget.branch) {
      invalidate();
    }
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    catalogSubscription?.cancel();
    catalogPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    search.dispose();
    discount.dispose();
    for (final c in quantities.values) {
      c.dispose();
    }
    super.dispose();
  }

  String failure(Object e) => e is PostgrestException && e.code == '40001'
      ? t(
          'تغيرت المسودة أو الأسعار أو إعدادات الضريبة. راجع النسخة المحفوظة قبل إعادة الحفظ.',
          'Draft, prices or tax settings changed. Review the saved version before saving again.',
        )
      : t(
          'تعذر التنفيذ. تحقق من الصلاحيات والكميات والمخزون والضريبة.',
          'Unable to continue. Check permissions, quantities, stock and tax rules.',
        );
  Future<void> load({bool recover = false, bool more = false}) async {
    if (!active || busy || pending != null) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.gateway.call('get_cashier_reviewed_context', {
        'p_branch': widget.branch,
        'p_search': search.text.trim(),
        'p_after': more && catalogue.isNotEmpty
            ? catalogue.last['item_id']
            : null,
      });
      if (!active || generation != epoch) return;
      if (data['quote_only'] != true || data['can_issue'] != false) {
        throw StateError('Unverified draft capability');
      }
      final items = List<Map<String, dynamic>>.from(data['items'] as List);
      contextData = data;
      catalogue = more ? [...catalogue, ...items] : items;
      if (recover) {
        final saved = await widget.gateway.call('get_cashier_reviewed_draft', {
          'p_branch': widget.branch,
          'p_draft': widget.initialDraftId,
        });
        if (!active || generation != epoch) return;
        if (saved['state'] != 'draft' && widget.initialDraftId != null) {
          throw StateError('Requested draft unavailable');
        }
        if (saved['state'] == 'draft') {
          final payload = Map<String, dynamic>.from(saved['payload'] as Map);
          draft = saved['draft_id'] as String;
          version = saved['version'] as int;
          quote = Map<String, dynamic>.from(saved['quote'] as Map);
          for (final line in List<Map<String, dynamic>>.from(
            quote!['lines'] as List,
          )) {
            final id = line['item_id'] as String;
            final key = cart.containsKey(id) ? '$id:${cart.length}' : id;
            cart[key] = Map<String, dynamic>.from(line);
            quantities[key] = TextEditingController(
              text: '${line['quantity']}',
            );
          }
          mode = payload['discount_mode'] as String;
          discount.text = '${payload['discount_value']}';
          dirty = false;
          if (data['catalogue_review_supported'] == true) {
            dirty = true;
            final review = await widget.gateway.call(
              'get_cashier_catalogue_review',
              {
                'p_branch': widget.branch,
                'p_draft': draft,
                'p_version': version,
              },
            );
            if (!active || generation != epoch) return;
            dirty = review['needs_review'] != false;
            applyCatalogueReview(review);
          }
        }
      }
    } catch (e) {
      if (active && generation == epoch) error = failure(e);
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> add(Map<String, dynamic> row) async {
    if (!editable) return;
    final itemId = row['item_id'] as String;
    final id =
        cart.entries
            .where((e) => e.value['item_id'] == itemId)
            .map((e) => e.key)
            .firstOrNull ??
        itemId;
    final isNewService = !cart.containsKey(id) && row['item_type'] == 'service';
    setState(() {
      if (cart.containsKey(id)) {
        final n = int.tryParse(quantities[id]!.text) ?? 0;
        quantities[id]!.text = '${n + 1}';
      } else {
        cart[id] = {...row, 'staff_ids': <String>[]};
        quantities[id] = TextEditingController(text: '1');
      }
      dirty = true;
    });
    if (isNewService && !await staffFor(id) && active && editable) {
      setState(() {
        cart.remove(id);
        quantities.remove(id)?.dispose();
      });
    }
  }

  Future<bool> staffFor(String id) async {
    if (!editable) return false;
    final selected = Set<String>.from(cart[id]!['staff_ids'] as List);
    final generation = epoch;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(
            t('موظفو هذا البند', 'Workers for this line'),
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: SizedBox(
            width: 420,
            height: MediaQuery.sizeOf(ctx).height * .42,
            child: ListView(
              children: [
                for (final s in List<Map<String, dynamic>>.from(
                  contextData!['staff'] as List,
                ))
                  CheckboxListTile(
                    title: Text(
                      '${s['name']}',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff071a36),
                      ),
                    ),
                    secondary: CircleAvatar(
                      radius: 28,
                      backgroundColor: const Color(0xffe8edf4),
                      child: s['photo_url'] is String
                          ? ClipOval(
                              child: Image.network(
                                s['photo_url'] as String,
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                                errorBuilder: (_, error, stack) => const Icon(
                                  Icons.person,
                                  size: 32,
                                  color: Color(0xff174b83),
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.person,
                              size: 32,
                              color: Color(0xff174b83),
                            ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    activeColor: const Color(0xff174b83),
                    value: selected.contains(s['staff_id']),
                    onChanged: (v) => update(() {
                      v == true
                          ? selected.add(s['staff_id'] as String)
                          : selected.remove(s['staff_id']);
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('رجوع', 'Back')),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: Text(t('حفظ الاختيار', 'Save selection')),
            ),
          ],
        ),
      ),
    );
    if (!active || generation != epoch || ok != true || !cart.containsKey(id)) {
      return false;
    }
    setState(() {
      cart[id]!['staff_ids'] = selected.toList()..sort();
      dirty = true;
    });
    return true;
  }

  Future<void> downloadRefund(String request, String paper) async {
    final generation = epoch;
    final arabic = ar;
    try {
      final document = await widget.gateway.call(
        'get_invoice_refund_document',
        {'p_request': request},
      );
      if (!active || generation != epoch) return;
      final receipt = Map<String, dynamic>.from(
        document['refund_receipt'] as Map,
      );
      if (receipt['refund_id'] != request ||
          receipt['refund_number'] is! String) {
        throw StateError('Invalid owned refund document');
      }
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf');
      final logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildInvoicePdf(
        document,
        font.buffer.asUint8List(),
        logo.buffer.asUint8List(),
        paper: paper,
        arabic: arabic,
      );
      if (!active || generation != epoch) return;
      await FilePicker.saveFile(
        dialogTitle: t('إيصال الاسترداد', 'Refund receipt'),
        fileName: '${receipt['refund_number']}.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
      );
    } catch (e) {
      if (active && generation == epoch) setState(() => error = failure(e));
    }
  }

  Future<void> openDrafts() async {
    if (!canStartNew) return;
    if (dirty && cart.isNotEmpty) {
      await save();
      if (!active || dirty || pending != null) return;
    }
    if (!mounted || !active) return;
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CashierOpenDraftsScreen(
          gateway: widget.gateway,
          branch: widget.branch,
        ),
      ),
    );
    if (!mounted || !active || id == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CashierInvoiceDraftScreen(
          gateway: widget.gateway,
          branch: widget.branch,
          initialDraftId: id,
        ),
      ),
    );
  }

  Future<void> startNew() async {
    if (!canStartNew) return;
    if (dirty && cart.isNotEmpty) {
      await save();
      if (!active || dirty || pending != null) return;
    }
    for (final c in quantities.values) {
      c.dispose();
    }
    quantities.clear();
    setState(() {
      cart.clear();
      draft = newOrderRequestId();
      version = 0;
      issued = false;
      bindingRevision = 0;
      quote = null;
      dirty = true;
      discount.text = '0';
      mode = 'fixed';
      error = null;
    });
  }

  Future<void> save() async {
    if (!active ||
        busy ||
        bindingBusy ||
        checkoutBusy ||
        issued ||
        cart.isEmpty) {
      return;
    }
    final generation = epoch;
    if (pending == null) {
      final items = <Map<String, dynamic>>[];
      for (final entry in cart.entries) {
        final value = numericInput(quantities[entry.key]!.text);
        if (!RegExp(r'^[1-9][0-9]{0,8}$').hasMatch(value)) {
          setState(
            () => error = t(
              'أدخل كمية صحيحة موجبة.',
              'Enter a positive integer quantity.',
            ),
          );
          return;
        }
        items.add({
          'item_id': entry.value['item_id'],
          'quantity': int.parse(value),
          'staff_ids': List<String>.from(entry.value['staff_ids'] as List),
        });
      }
      if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(numericInput(discount.text))) {
        setState(
          () => error = t(
            'أدخل خصمًا صحيحًا بمنزلتين عشريتين كحد أقصى.',
            'Enter a valid discount with at most two decimal places.',
          ),
        );
        return;
      }
      pending = Map<String, dynamic>.from(
        jsonDecode(
          jsonEncode({
            'p_request': newOrderRequestId(),
            'p_draft': draft,
            'p_expected_version': version,
            'p_branch': widget.branch,
            'p_items': items,
            'p_discount_mode': mode,
            'p_discount_value': numericInput(discount.text),
          }),
        ) as Map,
      );
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.gateway.call(
        'save_cashier_reviewed_draft',
        pending!,
      );
      if (!active || generation != epoch) return;
      if (result['draft_id'] != draft || result['version'] != version + 1) {
        throw StateError('Unverified draft receipt');
      }
      final next = Map<String, dynamic>.from(result['quote'] as Map);
      if (next['kind'] != 'cashier_cart_reviewed_quote_v2' ||
          next['quote_only'] != true ||
          next['can_issue'] != false ||
          next['earned_commission'] != false) {
        throw StateError('Not a draft quote');
      }
      quote = next;
      version = result['version'] as int;
      classServicePrices = const {};
      selectedVehicleClassCode = next['vehicle_class_code'] as String?;
      selectedVehicleClassNameAr = next['vehicle_class_name_ar'] as String?;
      selectedVehicleClassNameEn = next['vehicle_class_name_en'] as String?;
      if (next['vehicle_pricing_ready'] == true) {
        try {
          final pricing = await widget.gateway.call(
            'get_cashier_vehicle_service_prices',
            {'p_branch': widget.branch, 'p_draft': draft, 'p_version': version},
          );
          if (!active || generation != epoch) return;
          if (pricing['ready'] == true &&
              pricing['draft_version'] == version &&
              pricing['binding_version'] != null) {
            classServicePrices = Map<String, dynamic>.from(
              pricing['prices'] ?? const {},
            );
            selectedVehicleClassCode = pricing['vehicle_class_code'] as String?;
            selectedVehicleClassNameAr =
                pricing['vehicle_class_name_ar'] as String?;
            selectedVehicleClassNameEn =
                pricing['vehicle_class_name_en'] as String?;
          }
        } catch (_) {
          // Display prices from the reviewed line only; this optional list
          // never participates in checkout authorization.
        }
      }
      dirty = false;
      catalogNotice = null;
      catalogPriceChanges.clear();
      catalogueOriginalPrices.clear();
      pending = null;
    } catch (e) {
      if (active && generation == epoch) {
        error = failure(e);
        if (e is PostgrestException) {
          pending = null; // Definitive rejection; no automatic rebase.
        }
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff5f7fa),
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(
        t('تجهيز فاتورة متعددة البنود', 'Prepare a multi-line invoice'),
      ),
    ),
    body: invalid || !widget.gateway.current
        ? Center(
            child: Text(
              t(
                'أعد تسجيل الدخول لعرض المسودة.',
                'Sign in again to view the draft.',
              ),
            ),
          )
        : CashierWorkspaceLayout(
            children: [
              Text(
                t(
                  'راجع البنود والسعر من الخادم، ثم أصدر الفاتورة وأكّد التحصيل كلًّا على حدة.',
                  'Review server-priced lines, then issue the invoice and confirm collection separately.',
                ),
              ),
              OutlinedButton(
                onPressed: canStartNew ? startNew : null,
                child: Text(t('مسودة جديدة', 'New draft')),
              ),
              OutlinedButton(
                onPressed: canStartNew ? openDrafts : null,
                child: Text(t('الفواتير المفتوحة', 'Open invoices')),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(error!),
              if (catalogNotice != null) Text(catalogNotice!),
              TextField(
                controller: search,
                enabled: editable,
                decoration: InputDecoration(
                  labelText: t(
                    'بحث في الخدمات والمنتجات',
                    'Search services and products',
                  ),
                ),
                onSubmitted: (_) => load(),
              ),
              OutlinedButton(
                onPressed: editable ? () => load() : null,
                child: Text(t('بحث', 'Search')),
              ),
              CashierCatalogButtons(
                items: catalogue.map((item) {
                  if (item['item_type'] != 'service') {
                    return item;
                  }
                  return {
                    ...item,
                    'price': classServicePrices[item['item_id']],
                    'vehicle_price_verified': selectedVehicleClassCode != null,
                    'vehicle_price_available': classServicePrices.containsKey(
                      item['item_id'],
                    ),
                    'vehicle_class_code': selectedVehicleClassCode,
                  };
                }).toList(),
                vehicleClassName: ar
                    ? selectedVehicleClassNameAr
                    : selectedVehicleClassNameEn,
                categories: List<Map<String, dynamic>>.from(
                  contextData?['pos_categories'] ?? [],
                ),
                arabic: ar,
                enabled: editable,
                onAdd: add,
              ),
              if (contextData?['has_more'] == true)
                OutlinedButton(
                  onPressed: editable ? () => load(more: true) : null,
                  child: Text(t('تحميل المزيد', 'Load more')),
                ),
              const Divider(key: ValueKey('pos_draft_divider')),
              Text(
                t(
                  'بنود المسودة (${cart.length})',
                  'Draft lines (${cart.length})',
                ),
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff071a36),
                ),
              ),
              if (!dirty &&
                  quote != null &&
                  quote!['vehicle_pricing_ready'] == true)
                Card(
                  color: const Color(0xff071a36),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${t('الإجمالي المعتمد من الخادم', 'Server-calculated total')}: ${money(quote!['total'])} EGP',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              if (dirty && cart.isNotEmpty)
                Text(
                  t(
                    'احفظ المسودة لتحديث الإجمالي والخصومات والضرائب من الخادم.',
                    'Save the draft to refresh the server total, discounts and tax.',
                  ),
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xff174b83),
                  ),
                ),
              for (final entry in cart.entries)
                Card(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: Color(0xffc5cbd5)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          ar
                              ? '${entry.value['name']}'
                              : '${entry.value['name_en'] ?? entry.value['name']}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Color(0xff071a36),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          entry.value['item_type'] == 'service' &&
                                  displayedUnitPrice(entry.value) == null
                              ? t(
                                  'السعر مؤقت حتى ربط سيارة وفئتها؛ لا يمكن إصدار الخدمة قبل ذلك.',
                                  'Provisional until a vehicle and class are bound; this service cannot be issued yet.',
                                )
                              : '${t('سعر الوحدة', 'Unit price')}: ${money(displayedUnitPrice(entry.value))} EGP',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xff174b83),
                          ),
                        ),
                        TextField(
                          key: ValueKey('quantity-${entry.key}'),
                          controller: quantities[entry.key],
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                          enabled: editable,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: t('الكمية', 'Quantity'),
                          ),
                          onChanged: (_) => setState(() => dirty = true),
                        ),
                        if (entry.value['item_type'] == 'service')
                          OutlinedButton(
                            onPressed: editable
                                ? () => staffFor(entry.key)
                                : null,
                            child: Text(
                              t('اختيار موظفي البند', 'Choose line workers'),
                            ),
                          ),
                        TextButton(
                          onPressed: editable
                              ? () => setState(() {
                                  cart.remove(entry.key);
                                  quantities.remove(entry.key)?.dispose();
                                  dirty = true;
                                })
                              : null,
                          child: Text(t('حذف البند', 'Remove line')),
                        ),
                      ],
                    ),
                  ),
                ),
              if (contextData?['can_discount'] == true) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t('الخصم قبل الضريبة', 'Discount before tax'),
                  ),
                  initialValue: mode,
                  items: [
                    DropdownMenuItem(
                      value: 'fixed',
                      child: Text(t('مبلغ ثابت', 'Fixed amount')),
                    ),
                    DropdownMenuItem(
                      value: 'percentage',
                      child: Text(t('نسبة مئوية', 'Percentage')),
                    ),
                  ],
                  onChanged: editable
                      ? (v) => setState(() {
                          mode = v!;
                          dirty = true;
                        })
                      : null,
                ),
                TextField(
                  controller: discount,
                  enabled: editable,
                  decoration: InputDecoration(
                    labelText: t('قيمة الخصم', 'Discount value'),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() => dirty = true),
                ),
              ],
              FilledButton(
                onPressed:
                    !busy &&
                        !bindingBusy &&
                        !checkoutBusy &&
                        !issued &&
                        active &&
                        cart.isNotEmpty
                    ? save
                    : null,
                child: Text(
                  pending != null
                      ? t('إعادة محاولة نفس الحفظ', 'Retry the same save')
                      : t(
                          'حفظ المسودة وحساب السعر من الخادم',
                          'Save draft and calculate on server',
                        ),
                ),
              ),
              if (!dirty &&
                  quote != null &&
                  quote!['vehicle_pricing_ready'] != true)
                Card(
                  color: const Color(0xfffff4db),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      t(
                        'الأسعار الظاهرة مؤقتة. اربط العميل وسيارته المصنفة، ثم احفظ المسودة لإعادة حساب سعر كل خدمة حسب الفئة. لا يمكن إصدار الخدمة قبل اعتماد سعر الفئة.',
                        'Prices are provisional. Bind the customer and classified vehicle, then save again to calculate every service by class. Service issuance stays blocked until the class rate is confirmed.',
                      ),
                    ),
                  ),
                ),
              if (!dirty &&
                  quote != null &&
                  quote!['vehicle_pricing_ready'] == true) ...[
                Text(
                  '${t('قبل الخصم والضريبة', 'Before discount and tax')}: ${money(quote!['subtotal_before_discount_exact'])} EGP',
                ),
                Text(
                  '${t('الخصم', 'Discount')}: ${money(quote!['invoice_discount_exact'])} EGP',
                ),
                Text(
                  '${t('الضريبة', 'Tax')}: ${money(quote!['tax_amount_exact'])} EGP',
                ),
                Text(
                  '${t('الإجمالي', 'Total')}: ${money(quote!['total'])} EGP',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Color(0xff071a36),
                  ),
                ),
                Text(
                  t(
                    'عمولة الخدمة قبل الخصم مع استبعاد الضريبة؛ تقديرية ولا تستحق قبل تأكيد تنفيذ الخدمة.',
                    'Service commissions exclude tax and precede discounts; estimates are not earned until verified service completion.',
                  ),
                ),
              ],
              if (!dirty && quote != null && !issued && !checkoutBusy)
                CashierCustomerBinding(
                  key: ValueKey('binding-$draft-$version'),
                  gateway: widget.gateway,
                  branch: widget.branch,
                  draft: draft,
                  version: version,
                  onMutationBusy: (value) {
                    if (active) {
                      setState(() {
                        if (bindingBusy && !value) {
                          bindingRevision++;
                          dirty = true;
                          classServicePrices = const {};
                          selectedVehicleClassCode = null;
                          selectedVehicleClassNameAr = null;
                          selectedVehicleClassNameEn = null;
                        }
                        bindingBusy = value;
                      });
                    }
                  },
                ),
              if (!dirty &&
                  quote != null &&
                  quote!['vehicle_pricing_ready'] == true &&
                  !issued)
                CashierCheckoutPanel(
                  key: ValueKey('checkout-$draft-$version'),
                  gateway: widget.gateway,
                  branch: widget.branch,
                  draft: draft,
                  version: version,
                  bindingRevision: bindingRevision,
                  hasServices: (quote!['lines'] as List? ?? []).any(
                    (e) => e['item_type'] == 'service',
                  ),
                  externalBusy: bindingBusy || busy || catalogOffline,
                  onMutationBusy: (value) {
                    if (active) setState(() => checkoutBusy = value);
                  },
                  onIssued: () {
                    if (active && !issued) setState(() => issued = true);
                  },
                  onOpenInvoice: widget.gateway is SupabaseCashierCartGateway
                      ? (token, role) async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => InvoiceDocumentsScreen(
                                client:
                                    (widget.gateway
                                            as SupabaseCashierCartGateway)
                                        .client,
                                initialToken: token,
                                role: role,
                              ),
                            ),
                          );
                        }
                      : null,
                  onOpenWork: widget.gateway is SupabaseCashierCartGateway
                      ? (order) async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ServiceWorkScreen.forOrder(
                                client:
                                    (widget.gateway
                                            as SupabaseCashierCartGateway)
                                        .client,
                                order: order,
                              ),
                            ),
                          );
                        }
                      : null,
                  onManageShifts: widget.gateway is SupabaseCashierCartGateway
                      ? (role) async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CashierShiftsScreen(
                                client:
                                    (widget.gateway
                                            as SupabaseCashierCartGateway)
                                        .client,
                                role: role,
                              ),
                            ),
                          );
                        }
                      : null,
                  onDownloadRefund: downloadRefund,
                ),
            ],
          ),
  );
}
