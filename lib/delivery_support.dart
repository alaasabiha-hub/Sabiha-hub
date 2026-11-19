import 'app_config.dart';
import 'catalog_refresh.dart';
import 'catalog_media.dart';
import 'customer_visuals.dart';

import 'dart:async';
import 'dart:convert';

import 'branch_settings.dart';
import 'workflow.dart' show newOrderRequestId;
export 'workflow.dart' show newOrderRequestId;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Freezes the exact request until its outcome is known, including after timeout.
class FulfillmentCheckoutAttempt {
  Map<String, dynamic>? _payload;
  bool get unresolved => _payload != null;
  Map<String, dynamic> capture(Map<String, dynamic> proposed) {
    _payload ??= Map<String, dynamic>.from(
      jsonDecode(jsonEncode(proposed)) as Map,
    );
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(_payload)) as Map);
  }

  void succeeded() => _payload = null;
  bool rejected(Object error) {
    // Recognized SQL transaction rejections are definitive. HTTP/proxy/unknown
    // errors (including 500) may have lost a committed response.
    if (error is PostgrestException &&
        const {
          'P0001',
          '22023',
          '42501',
          '40001',
          '23514',
          '23503',
          '23505',
        }.contains(error.code)) {
      _payload = null;
      return true;
    }
    return false;
  }
}

/// Local storage contains only a per-user request UUID. The private server draft
/// retains personal checkout fields and the exact replay payload.
class DurableCheckoutRecovery {
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final Future<void> Function() clear;
  final Future<dynamic> Function(String, Map<String, dynamic>) rpc;
  DurableCheckoutRecovery({
    required this.read,
    required this.write,
    required this.clear,
    required this.rpc,
  });
  Future<Map<String, dynamic>> recover() async {
    final id = await read();
    var result = Map<String, dynamic>.from(
      await rpc('get_checkout_retry', {'p_request': id}) as Map,
    );
    if (result['state'] == 'absent' && id != null) {
      result = Map<String, dynamic>.from(
        await rpc('get_checkout_retry', {'p_request': null}) as Map,
      );
    }
    if (result['state'] == 'open' || result['state'] == 'succeeded') {
      await write(result['request_id'] as String);
    } else {
      await clear();
    }
    return result;
  }

  Future<Map<String, dynamic>> prepare(Map<String, dynamic> payload) async {
    await write(payload['p_request_id'] as String);
    return Map<String, dynamic>.from(
      await rpc('prepare_checkout_retry', {
        'p_request': payload['p_request_id'],
        'p_payload': payload,
      }) as Map,
    );
  }

  Future<void> acknowledge(String id) async {
    final result = Map<String, dynamic>.from(
      await rpc('acknowledge_checkout_retry', {'p_request': id}) as Map,
    );
    if (result['state'] != 'succeeded' || result['acknowledged'] != true) {
      throw StateError('Checkout receipt not acknowledged');
    }
    await clear();
  }

  Future<Map<String, dynamic>> reject(String id) async {
    final result = Map<String, dynamic>.from(
      await rpc('reject_checkout_retry', {'p_request': id}) as Map,
    );
    if (result['state'] == 'rejected') await clear();
    if (result['state'] == 'succeeded') {
      await write(result['request_id'] as String);
    }
    return result;
  }
}

bool validInternationalPhone(String phone) =>
    RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone);
const fulfillmentLabels = {
  'new': 'طلب جديد',
  'confirmed': 'تم التأكيد',
  'preparing': 'جاري التجهيز',
  'out_for_delivery': 'خرج للتوصيل',
  'delivered': 'تم التسليم',
  'cancelled': 'ملغي',
};
List<String> fulfillmentNext(String status, String method) => switch (status) {
  'new' => ['confirmed', 'cancelled'],
  'confirmed' => ['preparing', 'cancelled'],
  'preparing' => [
    method == 'delivery' ? 'out_for_delivery' : 'delivered',
    'cancelled',
  ],
  'out_for_delivery' => ['delivered', 'cancelled'],
  _ => [],
};
Uri whatsappSupportUri(String phone, String message, {bool web = false}) {
  if (!validInternationalPhone(phone)) {
    throw ArgumentError('International phone required');
  }
  return web
      ? Uri.https('web.whatsapp.com', '/send', {
          'phone': phone.substring(1),
          'text': message,
        })
      : Uri.https('wa.me', '/${phone.substring(1)}', {'text': message});
}

class WhatsAppSupportButton extends StatefulWidget {
  final SupabaseClient client;
  final String? reference;
  final String? branchId;
  const WhatsAppSupportButton({
    super.key,
    required this.client,
    this.reference,
    this.branchId,
  });
  @override
  State<WhatsAppSupportButton> createState() => _WhatsAppSupportButtonState();
}

class _WhatsAppSupportButtonState extends State<WhatsAppSupportButton> {
  late final Future<Map<String, dynamic>?> settings;
  @override
  void initState() {
    super.initState();
    settings = () async {
      final value = await widget.client
          .from('business_contact_delivery_settings')
          .select('whatsapp_enabled,whatsapp_phone,whatsapp_message')
          .eq('id', true)
          .maybeSingle();
      final branchId = widget.branchId ?? BranchSelection.current;
      if (value != null && branchId != null) {
        final branch = await widget.client
            .from('business_branches')
            .select('whatsapp_phone')
            .eq('branch_id', branchId)
            .maybeSingle();
        if (validInternationalPhone(branch?['whatsapp_phone'] ?? '')) {
          value['whatsapp_phone'] = branch!['whatsapp_phone'];
        }
      }
      return value;
    }();
  }

  Future<void> open(Map<String, dynamic> s) async {
    final reference = widget.reference;
    final text = TextEditingController(
      text:
          '${s['whatsapp_message']}${reference == null ? '' : '\nالمرجع: $reference'}',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تواصل معنا عبر واتساب'),
        content: TextField(
          controller: text,
          maxLines: 4,
          maxLength: 700,
          decoration: const InputDecoration(
            helperText: 'راجع الرسالة قبل فتح واتساب. لا تُضاف بياناتك الشخصية تلقائيًا.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('فتح واتساب'),
          ),
        ],
      ),
    );
    final message = text.text;
    text.dispose();
    if (accepted != true) return;
    try {
      final opened = await launchUrl(
        whatsappSupportUri(s['whatsapp_phone'], message, web: kIsWeb),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        final fallback = await launchUrl(
          whatsappSupportUri(s['whatsapp_phone'], message, web: true),
          mode: LaunchMode.platformDefault,
        );
        if (!fallback) throw StateError('No browser');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر فتح واتساب أو المتصفح. حاول مجددًا.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>?>(
    future: settings,
    builder: (c, s) {
      final value = s.data;
      if (value == null ||
          value['whatsapp_enabled'] != true ||
          !validInternationalPhone(value['whatsapp_phone'] ?? '')) {
        return const SizedBox.shrink();
      }
      return TextButton.icon(
        onPressed: () => open(value),
        icon: const Icon(Icons.chat_outlined),
        label: const Text('تواصل معنا عبر واتساب'),
      );
    },
  );
}

class FulfillmentShopScreen extends StatefulWidget {
  final SupabaseClient client;
  final Duration catalogRefreshInterval;
  const FulfillmentShopScreen({
    super.key,
    required this.client,
    this.catalogRefreshInterval = const Duration(seconds: 30),
  });
  @override
  State<FulfillmentShopScreen> createState() => _FulfillmentShopScreenState();
}

class _FulfillmentShopScreenState extends State<FulfillmentShopScreen> {
  List<Map<String, dynamic>> products = [], zones = [];
  final Map<String, int> cart = {};
  final address = TextEditingController(),
      phone = TextEditingController(),
      note = TextEditingController(),
      coupon = TextEditingController();
  List<Map<String, dynamic>> branches = [];
  String? branchId;
  String method = 'pickup';
  String? zone;
  String request = newOrderRequestId();
  Map<String, dynamic>? quote;
  bool loading = true, busy = false;
  CatalogRefresh? catalogRefresh;
  String? catalogNotice;
  String? error;
  bool deliveryEnabled = false;
  bool recovering = true;
  Map<String, dynamic>? resolvedOrder;
  late final DurableCheckoutRecovery recovery;
  StreamSubscription<AuthState>? checkoutAuthSubscription;
  late final Session? checkoutSession;
  bool checkoutInvalidated = false;
  bool get checkoutScopeActive =>
      mounted &&
      !checkoutInvalidated &&
      checkoutSession != null &&
      widget.client.auth.currentSession?.accessToken ==
          checkoutSession?.accessToken &&
      widget.client.auth.currentUser?.id == checkoutSession?.user.id;
  void requireCheckoutScope() {
    if (!checkoutScopeActive) throw StateError('Checkout account changed');
  }

  Future<SharedPreferences> get checkoutPreferences =>
      SharedPreferences.getInstance();
  String get checkoutPreferenceKey =>
      'checkout_retry_uuid_${checkoutSession?.user.id}';
  final attempt = FulfillmentCheckoutAttempt();
  bool get editsLocked =>
      !checkoutScopeActive ||
      busy ||
      recovering ||
      attempt.unresolved ||
      resolvedOrder != null;
  @override
  void initState() {
    super.initState();
    checkoutSession = widget.client.auth.currentSession;
    checkoutAuthSubscription = widget.client.auth.onAuthStateChange.listen((
      event,
    ) {
      final initialReplay =
          event.session?.accessToken == checkoutSession?.accessToken &&
          event.session?.user.id == checkoutSession?.user.id &&
          (event.event == AuthChangeEvent.initialSession ||
              event.event == AuthChangeEvent.signedIn ||
              event.event == AuthChangeEvent.tokenRefreshed);
      if (initialReplay || checkoutInvalidated || !mounted) return;
      setState(() {
        checkoutInvalidated = true;
        cart.clear();
        quote = null;
        resolvedOrder = null;
        for (final controller in [address, phone, note, coupon]) {
          controller.clear();
        }
        products = [];
        zones = [];
        branches = [];
        attempt.succeeded();
        busy = false;
        recovering = false;
        loading = false;
      });
    });
    recovery = DurableCheckoutRecovery(
      read: () async {
        requireCheckoutScope();
        final preferences = await checkoutPreferences;
        requireCheckoutScope();
        return preferences.getString(checkoutPreferenceKey);
      },
      write: (id) async {
        requireCheckoutScope();
        final preferences = await checkoutPreferences;
        requireCheckoutScope();
        if (!await preferences.setString(checkoutPreferenceKey, id)) {
          throw StateError('Could not save retry identity');
        }
      },
      clear: () async {
        requireCheckoutScope();
        final preferences = await checkoutPreferences;
        requireCheckoutScope();
        if (!await preferences.remove(checkoutPreferenceKey)) {
          throw StateError('Could not clear retry identity');
        }
      },
      rpc: (name, params) async {
        requireCheckoutScope();
        final result = await widget.client.rpc(name, params: params);
        requireCheckoutScope();
        return result;
      },
    );
    initializeCheckout();
    catalogRefresh = CatalogRefresh(
      interval: widget.catalogRefreshInterval,
      refresh: () => load(background: true),
      allowed: () =>
          checkoutScopeActive &&
          !loading &&
          !editsLocked &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
  }

  Future<void> initializeCheckout() async {
    if (!checkoutScopeActive) return;
    try {
      final saved = await recovery.recover();
      if (!mounted || !checkoutScopeActive) {
        return;
      }
      if (saved['state'] == 'succeeded') {
        request = saved['request_id'] as String;
        if (checkoutScopeActive) {
          showExistingOrder(Map<String, dynamic>.from(saved['order'] as Map));
        }
        return;
      }
      attempt.succeeded();
      if (saved['state'] == 'open') {
        final payload = Map<String, dynamic>.from(saved['payload'] as Map);
        attempt.capture(payload);
        request = payload['p_request_id'] as String;
        branchId = saved['branch_id'] as String?;
        method = payload['p_method'] as String;
        zone = payload['p_zone'] as String?;
        address.text = payload['p_address'] as String? ?? '';
        phone.text = payload['p_phone'] as String? ?? '';
        note.text = payload['p_note'] as String? ?? '';
        coupon.text = payload['p_coupon'] as String? ?? '';
        for (final row in payload['p_items'] as List) {
          cart[row['item_id'] as String] = (row['quantity'] as num).toInt();
        }
        quote = {
          'total': payload['p_expected_total'],
          'subtotal': '—',
          'discount': '—',
          'delivery_fee': '—',
        };
        error = customerText(
          context,
          'تم استعادة طلب غير مؤكد؛ أعد نفس الطلب للتحقق.',
          'Unconfirmed checkout restored. Retry the same request to resolve it.',
        );
      }
      if (saved['state'] == 'open') {
        recovering = false;
        if (checkoutScopeActive) setState(() => loading = false);
        return;
      }
      if (saved['state'] != 'open') {
        quote = null;
        request = newOrderRequestId();
      }
      recovering = false;
      await load();
    } catch (_) {
      if (checkoutScopeActive) {
        setState(() {
          loading = false;
          recovering = true;
          error = customerText(
            context,
            'تعذر استعادة حالة الطلب. أعد التحقق قبل إنشاء طلب جديد.',
            'Unable to restore checkout status. Check again before starting a new order.',
          );
        });
      }
    }
  }

  void showExistingOrder(Map<String, dynamic> order) {
    if (!checkoutScopeActive) return;
    setState(() {
      resolvedOrder = order;
      attempt.succeeded();
      loading = false;
      recovering = false;
      error = null;
    });
  }

  Future<void> acknowledgeAndView() async {
    if (!checkoutScopeActive) return;
    setState(() => busy = true);
    try {
      await recovery.acknowledge(request);
      if (!mounted || !checkoutScopeActive) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => FulfillmentOrdersScreen(client: widget.client),
        ),
      );
    } catch (_) {
      if (checkoutScopeActive) {
        setState(
          () => error = customerText(
            context,
            'تعذر تأكيد الاستلام. طلبك محفوظ؛ أعد المحاولة.',
            'Unable to acknowledge receipt. Your confirmed order is saved; try again.',
          ),
        );
      }
    } finally {
      if (checkoutScopeActive) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    catalogRefresh?.dispose();
    checkoutAuthSubscription?.cancel();
    for (final c in [address, phone, note, coupon]) {
      c.dispose();
    }
    super.dispose();
  }

  void changed(VoidCallback change) {
    if (editsLocked) return;
    setState(() {
      change();
      quote = null;
      request = newOrderRequestId();
      error = null;
    });
  }

  Future<void> load({bool background = false}) async {
    if (!checkoutScopeActive) return;
    try {
      final nextBranches = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_branches')
            .select()
            .eq('is_active', true)
            .order('name_ar'),
      );
      requireCheckoutScope();
      final requestedBranch =
          branchId ??
          (!AppConfig.multiBranchEnabled
              ? nextBranches.firstWhere(
                  (b) => b['is_default'] == true,
                )['branch_id']
              : BranchSelection.current ??
                    nextBranches.firstWhere(
                      (b) => b['is_default'] == true,
                      orElse: () => nextBranches.first,
                    )['branch_id']);
      final rows = await widget.client
          .from('business_catalog_items')
          .select(
            'item_id,name,name_en,price,description,description_en',
          )
          .eq('branch_id', requestedBranch)
          .eq('item_type', 'product')
          .eq('is_active', true)
          .eq('is_public', true)
          .order('name');
      requireCheckoutScope();
      final nextProducts = List<Map<String, dynamic>>.from(rows);
      try {
        await enrichCatalogImages(widget.client, nextProducts);
      } catch (_) {
        /* Product icon remains available. */
      }
      requireCheckoutScope();
      final nextZones = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_delivery_zones')
            .select()
            .eq('branch_id', requestedBranch)
            .eq('is_active', true)
            .order('name'),
      );
      requireCheckoutScope();
      if (background && (editsLocked || branchId != requestedBranch)) return;
      final details = nextBranches.firstWhere(
        (b) => b['branch_id'] == requestedBranch,
      );
      String cartPricing(List<Map<String, dynamic>> rows) => jsonEncode(
        rows
            .where((x) => cart.containsKey(x['item_id']))
            .map((x) => [x['item_id'], x['price']])
            .toList(),
      );
      final changedPrice =
          background &&
          cart.isNotEmpty &&
          (cartPricing(products) != cartPricing(nextProducts) ||
              deliveryEnabled != (details['delivery_enabled'] == true) ||
              jsonEncode(zones) != jsonEncode(nextZones));
      setState(() {
        branches = nextBranches;
        branchId = requestedBranch;
        products = nextProducts;
        zones = nextZones;
        deliveryEnabled = details['delivery_enabled'] == true;
        loading = false;
        if (changedPrice) {
          quote = null;
          request = newOrderRequestId();
          catalogNotice = customerText(
            context,
            'تغير السعر أو توفر بند. راجع السلة وأعد حساب الإجمالي من الخادم قبل التأكيد.',
            'Price or availability changed. Review the cart and request a fresh server quote before confirming.',
          );
        }
      });
    } catch (_) {
      if (checkoutScopeActive && !(background && editsLocked)) {
        setState(() {
          loading = false;
          if (background) quote = null;
          error = customerText(
            context,
            'تعذر تحميل المتجر. أعد المحاولة.',
            'Unable to load the shop. Try again.',
          );
        });
      }
    }
  }

  List<Map<String, dynamic>> get items =>
      cart.entries.map((e) => {'item_id': e.key, 'quantity': e.value}).toList();
  Future<void> review() async {
    if (editsLocked) return;
    if (method == 'delivery' &&
        (zone == null ||
            address.text.trim().length < 10 ||
            !validInternationalPhone(phone.text.trim()))) {
      setState(
        () => error = customerText(
          context,
          'اختر منطقة متاحة وأدخل عنوانًا تفصيليًا ورقمًا دوليًا يبدأ بـ +.',
          'Choose an available zone, a detailed address and an international phone number starting with +.',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final q = await widget.client.rpc(
        'quote_product_fulfillment',
        params: {
          'p_items': items,
          'p_method': method,
          'p_zone': method == 'delivery' ? zone : null,
          'p_coupon': coupon.text.trim().toUpperCase(),
        },
      );
      if (checkoutScopeActive) {
        setState(() => quote = Map<String, dynamic>.from(q as Map));
      }
    } catch (_) {
      if (checkoutScopeActive) {
        setState(
          () => error = customerText(
            context,
            'تعذر التسعير. تحقق من المنطقة والحد الأدنى والمخزون والكوبون.',
            'Unable to quote. Check the zone, minimum order, stock and coupon.',
          ),
        );
      }
    } finally {
      if (checkoutScopeActive) setState(() => busy = false);
    }
  }

  Future<void> place() async {
    if (!checkoutScopeActive || quote == null || busy || recovering) return;
    setState(() {
      busy = true;
      error = null;
    });
    bool placing = false;
    final payload = attempt.capture({
      'p_items': items,
      'p_request_id': request,
      'p_method': method,
      'p_zone': method == 'delivery' ? zone : null,
      'p_address': method == 'delivery' ? address.text.trim() : null,
      'p_phone': method == 'delivery' ? phone.text.trim() : null,
      'p_note': note.text.trim(),
      'p_coupon': coupon.text.trim().toUpperCase(),
      'p_expected_total': quote!['total'],
    });
    try {
      final prepared = await recovery.prepare(payload);
      if (prepared['state'] == 'succeeded') {
        attempt.succeeded();
        showExistingOrder(Map<String, dynamic>.from(prepared['order'] as Map));
        return;
      }
      if (prepared['state'] != 'open') {
        attempt.succeeded();
        await recovery.clear();
        request = newOrderRequestId();
        quote = null;
        return;
      }
      requireCheckoutScope();
      placing = true;
      await widget.client.rpc('place_product_fulfillment', params: payload);
      // Discover the committed order; retain UUID until the displayed result
      // is explicitly acknowledged by the customer.
      final resolved = await recovery.recover();
      if (resolved['state'] != 'succeeded') {
        throw StateError('Order acknowledgement unavailable');
      }
      attempt.succeeded();
      showExistingOrder(Map<String, dynamic>.from(resolved['order'] as Map));
    } catch (failure) {
      if (!checkoutScopeActive) return;
      if (!placing) {
        await initializeCheckout();
        return;
      }
      bool definitive = false;
      if (placing) {
        final probe = FulfillmentCheckoutAttempt()..capture(payload);
        if (probe.rejected(failure)) {
          try {
            final resolved = await recovery.reject(request);
            if (resolved['state'] == 'succeeded') {
              attempt.succeeded();
              showExistingOrder(
                Map<String, dynamic>.from(resolved['order'] as Map),
              );
              return;
            }
            definitive = resolved['state'] == 'rejected';
          } catch (_) {
            /* Keep UUID and exact payload when resolution is uncertain. */
          }
        }
      }
      if (definitive) {
        attempt.succeeded();
        request = newOrderRequestId();
        quote = null;
      }
      if (checkoutScopeActive) {
        setState(
          () => error = definitive
              ? customerText(
                  context,
                  'تم رفض الطلب. راجع البيانات والسعر وأعد المحاولة.',
                  'Order rejected. Review details and quote before trying again.',
                )
              : customerText(
                  context,
                  'نتيجة الطلب غير مؤكدة. التعديل مقفل؛ أعد نفس الطلب للتحقق دون تكرار.',
                  'Order outcome unconfirmed. Editing is locked; retry the same request to resolve it.',
                ),
        );
      }
    } finally {
      if (checkoutScopeActive) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => !checkoutScopeActive
      ? Scaffold(
          appBar: AppBar(title: Text(customerText(context, 'المتجر', 'Shop'))),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                customerText(
                  context,
                  'تغيّر حساب الدخول. افتح المتجر مجددًا للمتابعة بأمان.',
                  'Your sign-in changed. Reopen the shop to continue securely.',
                ),
              ),
            ),
          ),
        )
      : PopScope(
          canPop: !attempt.unresolved && !recovering && resolvedOrder == null,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && attempt.unresolved) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    customerText(
                      context,
                      'تحقق من نتيجة الطلب بإعادة نفس الطلب قبل المغادرة.',
                      'Resolve this order by retrying the same request before leaving.',
                    ),
                  ),
                ),
              );
            }
          },
          child: CustomerAdaptiveFrame(
            title: customerText(
              context,
              'المتجر وسلة المشتريات',
              'Shop & basket',
            ),
            subtitle: customerText(
              context,
              'منتجات الفرع والسعر النهائي من الخادم',
              'Branch products and server-confirmed totals',
            ),
            selected: 3,
            appBar: AppBar(
              title: Text(
                customerText(
                  context,
                  'المنتجات · توصيل أو استلام',
                  'Products · delivery or pickup',
                ),
              ),
            ),
            body: loading
                ? const Center(child: CircularProgressIndicator())
                : resolvedOrder != null
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      CustomerPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              customerText(
                                context,
                                'تم تأكيد الطلب ${resolvedOrder!['order_number']}',
                                'Order ${resolvedOrder!['order_number']} confirmed',
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${customerText(context, 'الإجمالي النهائي', 'Final total')}: ${resolvedOrder!['total']} EGP',
                            ),
                            if (error != null)
                              Text(
                                error!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            FilledButton(
                              onPressed: busy ? null : acknowledgeAndView,
                              child: Text(
                                customerText(
                                  context,
                                  'عرض الطلب المؤكد',
                                  'View confirmed order',
                                ),
                              ),
                            ),
                            if (busy) const LinearProgressIndicator(),
                          ],
                        ),
                      ),
                    ],
                  )
                : attempt.unresolved
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      CustomerPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              customerText(
                                context,
                                'طلب محفوظ بانتظار التحقق',
                                'Saved checkout awaiting resolution',
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${customerText(context, 'الإجمالي الأصلي', 'Original total')}: ${attempt.capture({})['p_expected_total']} EGP',
                            ),
                            if (error != null)
                              Text(
                                error!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: busy
                                  ? null
                                  : recovering
                                  ? initializeCheckout
                                  : place,
                              child: Text(
                                customerText(
                                  context,
                                  'التحقق بإعادة نفس الطلب',
                                  'Retry same request',
                                ),
                              ),
                            ),
                            if (busy) const LinearProgressIndicator(),
                          ],
                        ),
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (recovering)
                        FilledButton(
                          onPressed: busy ? null : initializeCheckout,
                          child: Text(
                            customerText(
                              context,
                              'إعادة التحقق من الطلب',
                              'Check checkout status again',
                            ),
                          ),
                        ),
                      if (AppConfig.multiBranchEnabled && branches.isNotEmpty)
                        DropdownButtonFormField<String>(
                          key: ValueKey(branchId),
                          initialValue: branchId,
                          decoration: InputDecoration(
                            labelText: customerText(context, 'الفرع', 'Branch'),
                          ),
                          items: branches
                              .map(
                                (b) => DropdownMenuItem(
                                  value: b['branch_id'] as String,
                                  child: Text(branchName(b, context)),
                                ),
                              )
                              .toList(),
                          onChanged: editsLocked
                              ? null
                              : (v) {
                                  changed(() {
                                    branchId = v;
                                    BranchSelection.current = v;
                                    cart.clear();
                                    zone = null;
                                    method = 'pickup';
                                    loading = true;
                                  });
                                  load();
                                },
                        ),
                      if (error != null)
                        Text(error!, style: const TextStyle(color: Colors.red)),
                      if (products.isEmpty)
                        Text(
                          customerText(
                            context,
                            'لا توجد منتجات متاحة.',
                            'No products available.',
                          ),
                        ),
                      ...products.map((p) {
                        final id = p['item_id'] as String;
                        final qty = cart[id] ?? 0;
                        return CustomerPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: customerBlue.withValues(
                                        alpha: .25,
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child:
                                        p['image_display_url'] is String ||
                                            p['image_url'] is String &&
                                                Uri.tryParse(p['image_url'])
                                                        ?.scheme ==
                                                    'https'
                                        ? Image.network(
                                            (p['image_display_url'] ??
                                                    p['image_url'])
                                                as String,
                                            width: 70,
                                            height: 70,
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, error, stack) =>
                                                const Icon(
                                                  Icons.shopping_bag_outlined,
                                                  color: customerIce,
                                                  size: 34,
                                                ),
                                          )
                                        : const Icon(
                                            Icons.shopping_bag_outlined,
                                            color: customerIce,
                                            size: 34,
                                          ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          customerText(
                                            context,
                                            '${p['name']}',
                                            (p['name_en'] as String?)
                                                        ?.trim()
                                                        .isNotEmpty ==
                                                    true
                                                ? p['name_en'] as String
                                                : '${p['name']}',
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          '${p['price']} EGP',
                                          style: const TextStyle(
                                            color: customerGold,
                                            fontSize: 21,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    customerText(context, 'الكمية', 'Quantity'),
                                    style: const TextStyle(color: customerIce),
                                  ),
                                  Row(
                                    children: [
                                      IconButton(
                                        tooltip: customerText(
                                          context,
                                          'تقليل الكمية',
                                          'Decrease quantity',
                                        ),
                                        onPressed: editsLocked || qty == 0
                                            ? null
                                            : () => changed(() {
                                                if (qty == 1) {
                                                  cart.remove(id);
                                                } else {
                                                  cart[id] = qty - 1;
                                                }
                                              }),
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                          color: customerGold,
                                        ),
                                      ),
                                      Text(
                                        '$qty',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: customerText(
                                          context,
                                          'زيادة الكمية',
                                          'Increase quantity',
                                        ),
                                        onPressed: editsLocked || qty >= 100
                                            ? null
                                            : () => changed(
                                                () => cart[id] = qty + 1,
                                              ),
                                        icon: const Icon(
                                          Icons.add_circle_outline,
                                          color: customerGold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      DropdownButtonFormField<String>(
                        initialValue: method,
                        decoration: InputDecoration(
                          labelText: customerText(
                            context,
                            'طريقة الاستلام',
                            'Fulfillment method',
                          ),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'pickup',
                            child: Text(
                              customerText(
                                context,
                                'استلام من المكان',
                                'Branch pickup',
                              ),
                            ),
                          ),
                          if (deliveryEnabled)
                            DropdownMenuItem(
                              value: 'delivery',
                              child: Text(
                                customerText(
                                  context,
                                  'توصيل للعنوان',
                                  'Address delivery',
                                ),
                              ),
                            ),
                        ],
                        onChanged: editsLocked
                            ? null
                            : (v) => changed(() => method = v!),
                      ),
                      if (!deliveryEnabled)
                        Text(
                          customerText(
                            context,
                            'خدمة التوصيل متوقفة حاليًا. الاستلام من المكان متاح.',
                            'Delivery is currently disabled. Branch pickup is available.',
                          ),
                        ),
                      if (method == 'delivery') ...[
                        DropdownButtonFormField<String>(
                          initialValue: zone,
                          decoration: InputDecoration(
                            labelText: customerText(
                              context,
                              'منطقة عنوان التوصيل',
                              'Delivery zone',
                            ),
                          ),
                          items: zones
                              .map(
                                (z) => DropdownMenuItem(
                                  value: z['zone_id'] as String,
                                  child: Text(
                                    '${z['name']} · ${z['fee']} ${customerText(context, 'ج.م', 'EGP')}',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: editsLocked
                              ? null
                              : (v) => changed(() => zone = v),
                        ),
                        Text(
                          customerText(
                            context,
                            'يجب أن يقع عنوانك داخل المنطقة المختارة. العناوين خارج المناطق المتاحة غير مقبولة.',
                            'Your address must be inside the selected service zone.',
                          ),
                        ),
                        TextField(
                          controller: address,
                          enabled: !editsLocked,
                          maxLength: 700,
                          maxLines: 3,
                          onChanged: (_) => changed(() {}),
                          decoration: InputDecoration(
                            labelText: customerText(
                              context,
                              'المدينة، المنطقة، الشارع، المبنى، الدور والعلامة المميزة',
                              'City, area, street, building, floor and landmark',
                            ),
                          ),
                        ),
                        TextField(
                          controller: phone,
                          enabled: !editsLocked,
                          keyboardType: TextInputType.phone,
                          maxLength: 16,
                          onChanged: (_) => changed(() {}),
                          decoration: InputDecoration(
                            labelText: customerText(
                              context,
                              'رقم الهاتف بصيغة دولية +...',
                              'Phone number in international format +...',
                            ),
                          ),
                        ),
                      ],
                      if (catalogNotice != null)
                        Text(
                          catalogNotice!,
                          style: const TextStyle(color: customerIce),
                        ),
                      for (final id in cart.keys.where(
                        (id) => !products.any((p) => p['item_id'] == id),
                      ))
                        ListTile(
                          title: Text(
                            customerText(
                              context,
                              'بند لم يعد متاحًا — الكمية ${cart[id]}',
                              'Unavailable item — quantity ${cart[id]}',
                            ),
                            style: const TextStyle(color: customerIce),
                          ),
                          trailing: IconButton(
                            tooltip: customerText(
                              context,
                              'حذف البند غير المتاح',
                              'Remove unavailable item',
                            ),
                            onPressed: editsLocked
                                ? null
                                : () => changed(() => cart.remove(id)),
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: customerIce,
                            ),
                          ),
                        ),
                      TextField(
                        controller: note,
                        enabled: !editsLocked,
                        maxLength: 1000,
                        maxLines: 2,
                        onChanged: (_) => changed(() {}),
                        decoration: InputDecoration(
                          labelText: customerText(
                            context,
                            'ملاحظات التوصيل أو الاستلام',
                            'Delivery or pickup notes',
                          ),
                        ),
                      ),
                      TextField(
                        controller: coupon,
                        enabled: !editsLocked,
                        onChanged: (_) => changed(() {}),
                        decoration: InputDecoration(
                          labelText: customerText(
                            context,
                            'كود الخصم (اختياري)',
                            'Discount code (optional)',
                          ),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: editsLocked || cart.isEmpty ? null : review,
                        child: Text(
                          customerText(
                            context,
                            'مراجعة السعر من الخادم',
                            'Review server quote',
                          ),
                        ),
                      ),
                      if (quote != null)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                Text(
                                  '${customerText(context, 'المنتجات', 'Products')}: ${quote!['subtotal']} EGP\n${customerText(context, 'الخصم', 'Discount')}: ${quote!['discount']} EGP\n${customerText(context, 'رسوم التوصيل', 'Delivery fee')}: ${quote!['delivery_fee']} EGP\n${customerText(context, 'الإجمالي النهائي', 'Final total')}: ${quote!['total']} EGP',
                                ),
                                Text(
                                  customerText(
                                    context,
                                    'الدفع عند التوصيل أو الاستلام',
                                    'Pay on delivery or pickup',
                                  ),
                                ),
                                FilledButton(
                                  onPressed: busy ? null : place,
                                  child: Text(
                                    customerText(
                                      context,
                                      attempt.unresolved
                                          ? 'التحقق بإعادة نفس الطلب'
                                          : 'تأكيد الطلب',
                                      attempt.unresolved
                                          ? 'Retry same request'
                                          : 'Confirm order',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (busy)
                        const Center(child: CircularProgressIndicator()),
                      WhatsAppSupportButton(client: widget.client),
                    ],
                  ),
          ),
        );
}

class FulfillmentOrdersScreen extends StatefulWidget {
  final SupabaseClient client;
  final String? role;
  const FulfillmentOrdersScreen({super.key, required this.client, this.role});
  @override
  State<FulfillmentOrdersScreen> createState() =>
      _FulfillmentOrdersScreenState();
}

class _FulfillmentOrdersScreenState extends State<FulfillmentOrdersScreen> {
  List<Map<String, dynamic>> rows = [], staff = [], notifications = [];
  String? error;
  bool busy = false;
  Timer? timer;
  bool get management => widget.role == 'owner' || widget.role == 'manager';
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 20), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) return;
    try {
      final result = await widget.client
          .from('business_order_fulfillments')
          .select('*,business_orders(order_number)')
          .order('created_at', ascending: false)
          .limit(100);
      final directory = management
          ? await widget.client
                .from('staff_profiles')
                .select('user_id,full_name')
                .eq('is_active', true)
          : <Map<String, dynamic>>[];
      final notices = widget.role == null
          ? await widget.client
                .from('customer_order_notifications')
                .select(
                  'notification_id,status,created_at,business_orders(order_number)',
                )
                .order('created_at', ascending: false)
                .limit(20)
          : <Map<String, dynamic>>[];
      if (mounted) {
        setState(() {
          rows = List<Map<String, dynamic>>.from(result);
          staff = List<Map<String, dynamic>>.from(directory);
          notifications = List<Map<String, dynamic>>.from(notices);
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'تعذر تحميل الطلبات. أعد التحديث.');
    }
  }

  Future<void> update(
    Map<String, dynamic> f,
    String status,
    String? courier,
  ) async {
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'update_product_fulfillment',
        params: {
          'p_order': f['order_id'],
          'p_expected': f['status'],
          'p_status': status,
          'p_courier': courier,
        },
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر التحديث. تحقق من الصلاحية والتكليف وحدّث الطلب.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await load();
  }

  @override
  Widget build(BuildContext context) => CustomerAdaptiveFrame(
    enabled: widget.role == null,
    title: customerText(context, 'تتبع الطلبات', 'Track orders'),
    selected: 2,
    appBar: AppBar(
      title: const Text('التوصيل والاستلام'),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null) Text(error!),
        if (busy) const LinearProgressIndicator(),
        if (rows.isEmpty) const Text('لا توجد طلبات توصيل أو استلام.'),
        ...rows.map((f) {
          final ref =
              (f['business_orders'] as Map?)?['order_number']?.toString() ??
              f['order_id'];
          final status = f['status'] as String;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'طلب $ref',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${fulfillmentLabels[status]} · ${f['fulfillment_method'] == 'delivery' ? 'توصيل' : 'استلام من المكان'}',
                  ),
                  Text(
                    'المنتجات ${f['subtotal']} · الخصم ${f['discount']} · التوصيل ${f['delivery_fee']}\nالإجمالي ${f['total']} ج.م',
                  ),
                  if (f['fulfillment_method'] == 'delivery')
                    Text('${f['zone_name']}\n${f['address']}\n${f['phone']}'),
                  if (f['delivery_note'] != null) Text(f['delivery_note']),
                  if (management &&
                      !['delivered', 'cancelled'].contains(status))
                    DropdownButtonFormField<String>(
                      key: ValueKey('${f['order_id']}-${f['courier_id']}'),
                      initialValue:
                          staff.any((s) => s['user_id'] == f['courier_id'])
                          ? f['courier_id']
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'الموظف أو مندوب التوصيل',
                      ),
                      items: staff
                          .map(
                            (s) => DropdownMenuItem(
                              value: s['user_id'] as String,
                              child: Text(
                                '${s['full_name']} · ${(s['user_id'] as String).substring(28)}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: busy ? null : (id) => update(f, status, id),
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (management || widget.role == 'employee')
                        ...fulfillmentNext(status, f['fulfillment_method'])
                            .where(
                              (s) =>
                                  management ||
                                  s != 'cancelled' && s != 'confirmed',
                            )
                            .map(
                              (s) => OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => update(f, s, f['courier_id']),
                                child: Text(fulfillmentLabels[s]!),
                              ),
                            ),
                      if (widget.role == null &&
                          ['new', 'confirmed'].contains(status))
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => update(f, 'cancelled', f['courier_id']),
                          child: const Text('إلغاء الطلب'),
                        ),
                    ],
                  ),
                  WhatsAppSupportButton(
                    client: widget.client,
                    reference: 'طلب $ref',
                    branchId: f['branch_id'],
                  ),
                ],
              ),
            ),
          );
        }),
        if (notifications.isNotEmpty) ...[
          const Text(
            'إشعارات تحديث الطلبات',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          ...notifications.map(
            (n) => ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: Text(fulfillmentLabels[n['status']] ?? n['status']),
              subtitle: Text(
                '${(n['business_orders'] as Map?)?['order_number'] ?? ''} · ${n['created_at']}',
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class ContactDeliverySettingsScreen extends StatefulWidget {
  final SupabaseClient client;
  const ContactDeliverySettingsScreen({super.key, required this.client});
  @override
  State<ContactDeliverySettingsScreen> createState() =>
      _ContactDeliverySettingsScreenState();
}

class _ContactDeliverySettingsScreenState
    extends State<ContactDeliverySettingsScreen> {
  final phone = TextEditingController(),
      message = TextEditingController(),
      minimum = TextEditingController(),
      zoneName = TextEditingController(),
      fee = TextEditingController();
  bool enabled = false, whatsapp = false, busy = false;
  List<Map<String, dynamic>> zones = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [phone, message, minimum, zoneName, fee]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final s = await widget.client
          .from('business_contact_delivery_settings')
          .select()
          .eq('id', true)
          .single();
      final z = await widget.client
          .from('business_delivery_zones')
          .select()
          .order('name');
      if (mounted) {
        setState(() {
          enabled = s['delivery_enabled'];
          whatsapp = s['whatsapp_enabled'];
          phone.text = s['whatsapp_phone'];
          message.text = s['whatsapp_message'];
          minimum.text = s['minimum_subtotal'].toString();
          zones = List<Map<String, dynamic>>.from(z);
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'تعذر تحميل الإعدادات');
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'تعذر الحفظ. تحقق من القيم وصلاحية المالك.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('إعدادات التوصيل وواتساب')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        if (busy) const LinearProgressIndicator(),
        SwitchListTile(
          value: enabled,
          title: const Text('تفعيل التوصيل'),
          onChanged: (v) => setState(() => enabled = v),
        ),
        TextField(
          controller: minimum,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'حد أدنى لقيمة المنتجات قبل الخصم (0 بدون حد)',
          ),
        ),
        SwitchListTile(
          value: whatsapp,
          title: const Text('تفعيل زر واتساب'),
          onChanged: (v) => setState(() => whatsapp = v),
        ),
        TextField(
          controller: phone,
          decoration: const InputDecoration(
            labelText: 'رقم واتساب دولي يبدأ بـ +',
          ),
        ),
        TextField(
          controller: message,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'رسالة الترحيب العامة دون بيانات حساسة',
          ),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () => run(() async {
                  if (whatsapp && !validInternationalPhone(phone.text.trim())) {
                    throw ArgumentError();
                  }
                  await widget.client
                      .from('business_contact_delivery_settings')
                      .update({
                        'delivery_enabled': enabled,
                        'minimum_subtotal': double.parse(minimum.text),
                        'whatsapp_enabled': whatsapp,
                        'whatsapp_phone': phone.text.trim(),
                        'whatsapp_message': message.text.trim(),
                        'updated_at': DateTime.now().toUtc().toIso8601String(),
                      })
                      .eq('id', true)
                      .select()
                      .single();
                }),
          child: const Text('حفظ الإعدادات'),
        ),
        const Divider(),
        const Text('مناطق التوصيل ورسومها'),
        ...zones.map(
          (z) => ListTile(
            title: Text(z['name']),
            subtitle: Text('${z['fee']} ج.م'),
            trailing: Switch(
              value: z['is_active'],
              onChanged: busy
                  ? null
                  : (v) => run(() async {
                      await widget.client
                          .from('business_delivery_zones')
                          .update({'is_active': v})
                          .eq('zone_id', z['zone_id']);
                    }),
            ),
            onTap: () async {
              zoneName.text = z['name'];
              fee.text = z['fee'].toString();
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('تعديل المنطقة'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(controller: zoneName),
                      TextField(
                        controller: fee,
                        keyboardType: TextInputType.number,
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('إلغاء'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('حفظ'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await run(() async {
                  await widget.client
                      .from('business_delivery_zones')
                      .update({
                        'name': zoneName.text.trim(),
                        'fee': double.parse(fee.text),
                      })
                      .eq('zone_id', z['zone_id']);
                });
              }
              zoneName.clear();
              fee.clear();
            },
          ),
        ),
        TextField(
          controller: zoneName,
          decoration: const InputDecoration(
            labelText: 'اسم منطقة جديدة وحدودها المعروفة',
          ),
        ),
        TextField(
          controller: fee,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'رسوم المنطقة'),
        ),
        OutlinedButton(
          onPressed: busy
              ? null
              : () => run(() async {
                  await widget.client.from('business_delivery_zones').insert({
                    'name': zoneName.text.trim(),
                    'fee': double.parse(fee.text),
                  });
                  zoneName.clear();
                  fee.clear();
                }),
          child: const Text('إضافة منطقة'),
        ),
      ],
    ),
  );
}
