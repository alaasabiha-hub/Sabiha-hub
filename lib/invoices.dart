import 'dart:async';

import 'app_config.dart';
import 'customer_visuals.dart';
import 'invoice_presentation.dart';
import 'payment_checkout.dart';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'invoice_printing.dart';
import 'printer_device_settings.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// A new GoTrue subscriber receives its last event asynchronously. Only the
/// first event matching the already captured session is an initial replay.
bool matchesInitialAuthReplay(AuthState event, Session? initialSession) =>
    event.session?.accessToken == initialSession?.accessToken &&
    event.session?.user.id == initialSession?.user.id &&
    (event.event == AuthChangeEvent.initialSession ||
        event.event == AuthChangeEvent.signedIn ||
        event.event == AuthChangeEvent.tokenRefreshed);

final invoiceTokenPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
String? invoiceTokenFromInput(String input) {
  final value = input.trim();
  if (invoiceTokenPattern.hasMatch(value)) return value.toLowerCase();
  final uri = Uri.tryParse(value);
  if (uri == null || !['https', 'http'].contains(uri.scheme)) return null;
  final token = uri.queryParameters['invoice'];
  return token != null && invoiceTokenPattern.hasMatch(token)
      ? token.toLowerCase()
      : null;
}

String invoiceDocumentUrl(Map<String, dynamic> document) {
  final origin = (document['portal_origin'] as String? ?? '').replaceFirst(
    RegExp(r'/$'),
    '',
  );
  if (origin.isEmpty) {
    throw const FormatException('Configure the invoice website origin first');
  }
  return '$origin/?invoice=${document['document_token']}';
}

Future<Uint8List> buildInvoicePdf(
  Map<String, dynamic> document,
  Uint8List fontBytes,
  Uint8List logo, {
  String paper = 'A4',
  bool reprint = false,
  bool arabic = true,
}) async {
  if (!['A4', '58', '80'].contains(paper)) {
    throw const FormatException('Unsupported paper');
  }
  final snapshot = Map<String, dynamic>.from(document['snapshot']);
  final refundReceipt = document['refund_receipt'] is Map
      ? Map<String, dynamic>.from(document['refund_receipt'] as Map)
      : null;
  final lines = List<Map<String, dynamic>>.from(
    refundReceipt?['lines'] ?? snapshot['lines'],
  );
  final dateDocument = refundReceipt == null
      ? document
      : {...document, 'issued_at': refundReceipt['created_at']};
  num requiredAmount(dynamic value) {
    final parsed = num.tryParse('$value');
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      throw const FormatException('Missing or invalid refund amount');
    }
    return parsed;
  }

  String money(dynamic value) => requiredAmount(value).toStringAsFixed(2);
  String invoiceAmount(dynamic value) {
    if (snapshot['tax_configuration'] != 'owner_reviewed_versioned') {
      return '$value';
    }
    final amount = requiredAmount(value);
    return amount == num.parse(amount.toStringAsFixed(2))
        ? amount.toStringAsFixed(2)
        : amount.toStringAsFixed(5);
  }

  String refundExactSum(String key) => lines
      .fold<double>(
        0,
        (sum, line) => sum + requiredAmount(line[key]).toDouble(),
      )
      .toStringAsFixed(5);
  if (refundReceipt != null) {
    if (lines.isEmpty ||
        '${refundReceipt['refund_number'] ?? ''}'.isEmpty ||
        lines.any((line) => requiredAmount(line['quantity']) <= 0)) {
      throw const FormatException('Incomplete refund receipt');
    }
    final lineTotal = lines.fold<double>(
      0,
      (sum, line) => sum + requiredAmount(line['amount']).toDouble(),
    );
    if (lineTotal.toStringAsFixed(2) != money(refundReceipt['amount'])) {
      throw const FormatException(
        'Refund receipt total does not match its lines',
      );
    }
    refundExactSum('tax_amount_exact');
    refundExactSum('discount_exact');
  }

  final credits =
      refundReceipt == null && document['unpaid_service_credits'] is List
      ? List<Map<String, dynamic>>.from(document['unpaid_service_credits'])
      : <Map<String, dynamic>>[];
  if (credits.isNotEmpty) {
    final amount = credits.fold<num>(
      0,
      (sum, row) => sum + requiredAmount(row['amount']),
    );
    final tax = credits.fold<num>(
      0,
      (sum, row) => sum + requiredAmount(row['tax_amount_exact']),
    );
    if (credits.any(
          (row) =>
              '${row['number'] ?? ''}'.isEmpty ||
              requiredAmount(row['quantity']) != 1 ||
              requiredAmount(row['unit_number']) < 1,
        ) ||
        amount.toStringAsFixed(2) != money(document['unpaid_credit_amount']) ||
        tax.toStringAsFixed(5) !=
            requiredAmount(document['unpaid_credit_tax_amount_exact'])
                .toStringAsFixed(5) ||
        (requiredAmount(snapshot['total']) - amount).toStringAsFixed(2) !=
            money(document['adjusted_invoice_total'])) {
      throw const FormatException('Inconsistent unpaid service credit annex');
    }
    requiredAmount(document['amount_outstanding']);
  }

  final thermal = paper != 'A4';
  final format = thermal
      ? PdfPageFormat(
          double.parse(paper) * PdfPageFormat.mm,
          240 * PdfPageFormat.mm,
          marginAll: 4 * PdfPageFormat.mm,
        )
      : PdfPageFormat.a4;
  final ar = pw.Font.ttf(fontBytes.buffer.asByteData()),
      en = pw.Font.helvetica();
  pw.Widget text(String value, {double? size}) {
    value = value.replaceAll('—', '-').replaceAll('–', '-');
    final mixed =
        RegExp(r'[\u0600-\u06ff]').hasMatch(value) &&
        RegExp(r'[A-Za-z]').hasMatch(value);
    final parts = mixed
        ? RegExp(
                r'[\u0600-\u06ff]+(?:[ \t]+[\u0600-\u06ff]+)*|[^\u0600-\u06ff]+',
              )
              .allMatches(value)
              .map((m) => m[0]!.trim().replaceAll(RegExp(r'^/\s*|\s*/$'), ''))
              .where((part) => part.isNotEmpty)
              .toList()
        : [value];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        for (final part in parts)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 6),
            child: pw.Align(
              alignment: arabic
                  ? pw.Alignment.centerRight
                  : pw.Alignment.centerLeft,
              child: pw.Text(
                part,
                textDirection: RegExp(r'[\u0600-\u06ff]').hasMatch(part)
                    ? pw.TextDirection.rtl
                    : pw.TextDirection.ltr,
                style: pw.TextStyle(
                  font: RegExp(r'[\u0600-\u06ff]').hasMatch(part) ? ar : en,
                  fontFallback: [ar, en],
                  fontSize: size ?? (thermal ? 9 : 12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  pw.Widget field(String label, String value, {double? size}) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Directionality(
      textDirection: arabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(flex: 5, child: text(label, size: size)),
          pw.SizedBox(width: 8),
          pw.Expanded(flex: 6, child: text(value, size: size)),
        ],
      ),
    ),
  );
  String arabicDigits(String value) => value.replaceAllMapped(
    RegExp(r'[0-9]'),
    (m) => '٠١٢٣٤٥٦٧٨٩'[int.parse(m[0]!)],
  );

  final pdf = pw.Document(
    title: 'Sabiha Hub Invoice ${invoiceNumber(document)}',
  );
  final branch = Map<String, dynamic>.from(snapshot['branch']);
  pdf.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: pw.EdgeInsets.all(thermal ? 9 : 32),
      build: (_) => [
        pw.Center(
          child: pw.Image(pw.MemoryImage(logo), width: thermal ? 110 : 180),
        ),
        if (reprint)
          text('نسخة إعادة طباعة / REPRINT COPY', size: thermal ? 11 : 17),
        text(
          refundReceipt == null
              ? (arabic ? 'فاتورة' : 'Invoice')
              : (arabic ? 'إيصال استرداد داخلي' : 'Internal refund receipt'),
        ),
        text(
          refundReceipt == null
              ? invoiceNumber(document)
              : '${refundReceipt['refund_number']}',
        ),
        if (refundReceipt != null)
          field(
            arabic ? 'الفاتورة الأصلية' : 'Original invoice',
            invoiceNumber(document),
          ),
        text(
          arabic
              ? arabicDigits(invoiceDate(dateDocument, true))
              : invoiceDate(dateDocument, false),
        ),
        for (final key in ['name_ar', 'name_en', 'address_ar', 'address_en'])
          if ((branch[key] ?? '').toString().isNotEmpty) text('${branch[key]}'),
        field(
          arabic ? 'حالة الدفع' : 'Payment status',
          invoiceState(document['payment_status'], arabic),
        ),
        field(
          arabic ? 'وسيلة الدفع' : 'Payment method',
          invoiceState(document['payment_method'], arabic),
        ),
        for (final row in lines) ...[
          text('${arabic ? row['name'] : row['name_en'] ?? row['name']}'),
          text(
            refundReceipt == null
                ? '${row['quantity']} x ${row['unit_price']} = ${row['subtotal']} EGP'
                : '${row['quantity']} · ${arabic ? 'المبلغ المسترد' : 'Refunded amount'} ${money(row['amount'])} EGP',
          ),
        ],
        if (refundReceipt == null) ...[
          field(
            arabic ? 'الخصم' : 'Discount',
            '${invoiceAmount(snapshot['discount'])} EGP',
          ),
          if (snapshot['loyalty'] is Map) ...[
            field(
              arabic ? 'نقاط الولاء المستبدلة' : 'Loyalty points redeemed',
              '${(snapshot['loyalty'] as Map)['points']}',
            ),
            field(
              arabic ? 'خصم الولاء' : 'Loyalty discount',
              '${invoiceAmount((snapshot['loyalty'] as Map)['payable_discount'])} EGP',
            ),
          ],
          if (snapshot['visit_loyalty'] is Map) ...[
            text(
              arabic
                  ? 'مكافأة الزيارات: ${(snapshot['visit_loyalty'] as Map)['visits_redeemed']} زيارة تغطي ${(snapshot['visit_loyalty'] as Map)['covered_service_units']} وحدة خدمة'
                  : 'Visit reward: ${(snapshot['visit_loyalty'] as Map)['visits_redeemed']} visit(s), ${(snapshot['visit_loyalty'] as Map)['covered_service_units']} service unit(s)',
              size: thermal ? 8 : 10,
            ),
            field(
              arabic ? 'التغطية قبل الضريبة' : 'Coverage before tax',
              '${invoiceAmount((snapshot['visit_loyalty'] as Map)['net_coverage_exact'])} EGP',
              size: thermal ? 8 : 10,
            ),
            text(
              arabic
                  ? 'تخفيض الإجمالي شامل أثر الضريبة: ${invoiceAmount((snapshot['visit_loyalty'] as Map)['payable_discount'])} جنيه'
                  : 'Total reduction including tax effect: ${invoiceAmount((snapshot['visit_loyalty'] as Map)['payable_discount'])} EGP',
              size: thermal ? 8 : 10,
            ),
          ],
          if (snapshot['delivery_fee'] != null)
            field(
              arabic ? 'التوصيل' : 'Delivery',
              '${snapshot['delivery_fee']} EGP',
            ),
          field(
            arabic ? 'الضريبة' : 'Tax',
            snapshot['tax_amount'] == null
                ? (arabic ? 'غير مسجلة' : 'Not recorded')
                : '${invoiceAmount(snapshot['tax_amount'])} EGP',
          ),
          field(
            arabic ? 'الإجمالي' : 'Total',
            '${invoiceAmount(snapshot['total'])} EGP',
            size: thermal ? 13 : 18,
          ),
          if (snapshot['payable_rounding'] is num &&
              snapshot['payable_rounding'] != 0)
            field(
              arabic ? 'تسوية التقريب' : 'Rounding adjustment',
              '${(snapshot['payable_rounding'] as num).toStringAsFixed(5)} EGP',
            ),
          if (credits.isNotEmpty) ...[
            text(
              arabic ? 'تسويات الخدمات غير المدفوعة' : 'Unpaid service credits',
            ),
            for (final credit in credits) ...[
              text('${credit['number']}'),
              text(
                '${arabic ? credit['name'] : credit['name_en'] ?? credit['name']}',
              ),
              field(
                arabic ? 'وحدة الخدمة' : 'Service unit',
                '${credit['unit_number']}',
              ),
              field(
                arabic ? 'قيمة التسوية' : 'Credit amount',
                '${money(credit['amount'])} EGP',
              ),
            ],
            field(
              arabic ? 'إجمالي التسويات' : 'Total credits',
              '${money(document['unpaid_credit_amount'])} EGP',
            ),
            field(
              arabic ? 'الضريبة ضمن التسويات' : 'Tax included in credits',
              '${requiredAmount(document['unpaid_credit_tax_amount_exact']).toStringAsFixed(5)} EGP',
            ),
            field(
              arabic ? 'الإجمالي بعد التسويات' : 'Total after credits',
              '${money(document['adjusted_invoice_total'])} EGP',
            ),
            field(
              arabic ? 'المبلغ المستحق' : 'Amount outstanding',
              '${money(document['amount_outstanding'])} EGP',
            ),
            text(
              arabic
                  ? 'تسوية داخلية؛ الفاتورة الأصلية محفوظة. ليست مستندًا معتمدًا من مصلحة الضرائب.'
                  : 'Internal credit; original invoice preserved. Not an ETA-approved document.',
            ),
          ],
          if ((num.tryParse('${document['refund_amount']}') ?? 0) > 0) ...[
            field(
              arabic ? 'إجمالي المبلغ المسترد' : 'Total refunded',
              '${money(document['refund_amount'])} EGP',
            ),
            field(
              arabic ? 'صافي التحصيل' : 'Net collected',
              '${money(document['net_collected'])} EGP',
            ),
          ],
        ] else ...[
          field(
            arabic ? 'الخصم الأصلي المخصص' : 'Allocated original discount',
            '${refundExactSum('discount_exact')} EGP',
          ),
          field(
            arabic ? 'الضريبة المستردة' : 'Refunded tax',
            '${refundExactSum('tax_amount_exact')} EGP',
          ),
          field(
            arabic ? 'إجمالي الاسترداد' : 'Refund total',
            '${money(refundReceipt['amount'])} EGP',
            size: thermal ? 13 : 18,
          ),
          if (refundReceipt['payment_event_recorded'] == false)
            text(
              arabic
                  ? 'لا توجد حركة مالية لهذا الإيصال'
                  : 'No payment movement for this receipt',
            ),
          text(
            arabic
                ? 'إيصال داخلي غير معتمد من ETA'
                : 'Internal receipt, not ETA approved',
          ),
        ],
        if (document['service_status'] != null)
          field(
            arabic ? 'حالة الخدمة' : 'Service status',
            invoiceState(document['service_status'], arabic),
          ),
        pw.Inseparable(
          child: pw.Column(
            children: [
              pw.Center(
                child: pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: invoiceDocumentUrl(document),
                  width: thermal ? 95 : 135,
                  height: thermal ? 95 : 135,
                ),
              ),
              text(arabic ? 'يلزم تسجيل الدخول' : 'Sign-in required'),
              if (refundReceipt != null)
                text(
                  arabic
                      ? 'QR يفتح الفاتورة الأصلية وسجل الاسترداد'
                      : 'QR opens the original invoice and refund history',
                ),
            ],
          ),
        ),
      ],
    ),
  );
  return pdf.save();
}

/// Only an explicit authorization denial permits the typed customer fallback.
Future<Map<String, dynamic>> resolveInvoiceForViewer(
  SupabaseClient client,
  String token,
  String role,
) async {
  try {
    return Map<String, dynamic>.from(
      await client.rpc('resolve_invoice_document', params: {'p_token': token}),
    );
  } on PostgrestException catch (error) {
    if (role != 'customer' || error.code != '42501') rethrow;
    return reauthorizeOfflineInvoice(client, token);
  }
}

bool isOfflineHistoryInvoice(Map document) =>
    document['schema_version'] == 'offline-customer-invoice-v1' &&
    document['source_kind'] == 'offline_walk_in';

Future<Map<String, dynamic>> reauthorizeOfflineInvoice(
  SupabaseClient client,
  String token,
) async {
  final result = Map<String, dynamic>.from(
    await client.rpc(
      'get_my_offline_invoice_by_token',
      params: {'p_token': token},
    ),
  );
  if (!isOfflineHistoryInvoice(result) || result['document_token'] != token) {
    throw const FormatException('Typed invoice unavailable');
  }
  return result;
}

/// Cold/warm links are held until authentication; the database still verifies ownership.
class InvoiceLinkCoordinator {
  static final _links = AppLinks();
  static SupabaseClient? _client;
  static String? _pending;
  static bool _opening = false;
  static bool _authNavigationReady = false;
  static const _origin = String.fromEnvironment('INVOICE_PORTAL_ORIGIN');
  static void initialize(
    SupabaseClient client,
    GlobalKey<NavigatorState> navigator,
  ) {
    _client = client;
    _authNavigationReady = client.auth.currentUser != null;
    void receive(Uri uri) {
      final configured = Uri.tryParse(_origin);
      if (!['https', 'http'].contains(uri.scheme) ||
          configured == null ||
          !configured.hasAuthority ||
          _origin.isEmpty ||
          uri.origin != configured.origin) {
        return;
      }
      _pending = invoiceTokenFromInput(uri.toString());
      flush(client, navigator);
    }

    _links.uriLinkStream.listen(receive, onError: (_) {});
    _links.getInitialLink().then((uri) {
      if (uri != null) receive(uri);
    });
    client.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedIn ||
          event.event == AuthChangeEvent.signedOut) {
        _authNavigationReady = false;
      }
      flush(client, navigator);
    });
  }

  static void markNavigationReady(GlobalKey<NavigatorState> navigator) {
    _authNavigationReady = true;
    flushIfInitialized(navigator);
  }

  static void flushIfInitialized(GlobalKey<NavigatorState> navigator) {
    final client = _client;
    if (client != null) flush(client, navigator);
  }

  static void flush(
    SupabaseClient client,
    GlobalKey<NavigatorState> navigator,
  ) {
    if (_pending == null ||
        _opening ||
        !_authNavigationReady ||
        client.auth.currentUser == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (navigator.currentState == null ||
          _opening ||
          _pending == null ||
          !_authNavigationReady ||
          client.auth.currentUser == null) {
        return;
      }
      _opening = true;
      final token = _pending;
      _pending = null;
      try {
        var role = 'customer';
        try {
          final staff = await client
              .from('staff_profiles')
              .select('role,is_active,permissions')
              .eq('user_id', client.auth.currentUser!.id)
              .maybeSingle();
          if (staff != null &&
              staff['is_active'] == true &&
              (staff['role'] == 'owner' ||
                  staff['role'] == 'manager' ||
                  staff['role'] == 'employee' &&
                      staff['permissions'] is Map &&
                      staff['permissions']['cashier'] == true)) {
            role = staff['role'];
          }
        } catch (_) {}
        if (navigator.currentState == null) return;
        await navigator.currentState!.push(
          MaterialPageRoute(
            builder: (_) => InvoiceDocumentsScreen(
              client: client,
              initialToken: token,
              role: role,
            ),
          ),
        );
      } finally {
        _opening = false;
      }
    });
  }
}

class InvoiceDocumentsScreen extends StatefulWidget {
  final SupabaseClient client;
  final String? initialToken;
  final String role;
  final InvoicePrintingService? printingService;
  const InvoiceDocumentsScreen({
    super.key,
    required this.client,
    this.initialToken,
    this.role = 'customer',
    this.printingService,
  });
  @override
  State<InvoiceDocumentsScreen> createState() => _InvoiceDocumentsScreenState();
}

class _InvoiceDocumentsScreenState extends State<InvoiceDocumentsScreen> {
  final input = TextEditingController();
  final searchInput = TextEditingController();
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic>? document;
  String paper = 'A4';
  bool busy = false;
  String? error;
  StreamSubscription<AuthState>? _authSubscription;
  int _authorizationEpoch = 0;
  String? get _currentActor {
    try {
      return widget.client.auth.currentUser?.id;
    } on AuthException {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    try {
      final initialSession = widget.client.auth.currentSession;
      var replayPending = true;
      _authSubscription = widget.client.auth.onAuthStateChange.listen((event) {
        // GoTrue replays its latest event to a new subscriber. The session
        // captured before load already accounts for this one event; it is not
        // a new sign-in. Live sign-out, actor changes and later events still
        // invalidate every pending result and sensitive document.
        final sameInitialSession =
            replayPending && matchesInitialAuthReplay(event, initialSession);
        replayPending = false;
        if (sameInitialSession) return;
        if (event.event != AuthChangeEvent.initialSession) {
          _authorizationEpoch++;
          if (mounted &&
              (event.event == AuthChangeEvent.signedOut ||
                  event.event == AuthChangeEvent.signedIn ||
                  document != null && isOfflineHistoryInvoice(document!))) {
            setState(() {
              document = null;
              rows = [];
            });
          }
        }
      });
    } on AuthException {
      // External-token clients can still use their existing generic invoice path.
    }
    load();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    input.dispose();
    searchInput.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final epoch = _authorizationEpoch, actor = _currentActor;
    try {
      final data = List<Map<String, dynamic>>.from(
        await widget.client.rpc('list_invoice_documents'),
      );
      if (!mounted || epoch != _authorizationEpoch || actor != _currentActor) {
        return;
      }
      setState(() => rows = data);
      final token =
          widget.initialToken ??
          (data.isEmpty ? null : data.first['document_token'] as String);
      if (token != null) await open(token);
    } catch (_) {
      if (!mounted || epoch != _authorizationEpoch || actor != _currentActor) {
        return;
      }
      if (widget.initialToken != null) {
        await open(widget.initialToken!);
        return;
      }
      if (mounted) {
        setState(() => error = 'تعذر تحميل الفواتير / Unable to load invoices');
      }
    }
  }

  Future<void> open(String value) async {
    final token = invoiceTokenFromInput(value);
    if (token == null) {
      setState(() => error = 'رمز فاتورة غير صالح / Invalid invoice code');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      document = null;
    });
    try {
      final epoch = _authorizationEpoch;
      final result = await resolveInvoiceForViewer(
        widget.client,
        token,
        widget.role == 'customer' && _authSubscription == null
            ? 'external'
            : widget.role,
      );
      if (mounted && epoch == _authorizationEpoch) {
        setState(() => document = result);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          document = null;
          error = 'الفاتورة غير متاحة أو غير مصرح بها / Invoice unavailable or not authorized';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> search() async {
    final epoch = _authorizationEpoch, actor = _currentActor;
    try {
      final found = List<Map<String, dynamic>>.from(
        await widget.client.rpc(
          'search_invoice_documents',
          params: {'p_query': searchInput.text.trim()},
        ),
      );
      if (!mounted || epoch != _authorizationEpoch || actor != _currentActor) {
        return;
      }
      setState(() {
        rows = found;
        document = null;
        error = null;
      });
      if (found.isNotEmpty) await open(found.first['document_token']);
    } catch (_) {
      if (mounted && epoch == _authorizationEpoch && actor == _currentActor) {
        setState(() {
          if (document != null && isOfflineHistoryInvoice(document!)) {
            document = null;
            rows = [];
          }
          error = customerText(context, 'تعذر البحث', 'Search unavailable');
        });
      }
    }
  }

  Future<Uint8List> pdf(
    Map<String, dynamic> doc, {
    String? size,
    bool reprint = false,
  }) async {
    final exportEpoch = _authorizationEpoch;
    final exportActor = _currentActor;
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf'),
        logo = await rootBundle.load('assets/sabiha_brand_approved.png');
    var fresh = doc;
    if (isOfflineHistoryInvoice(doc) &&
        (!mounted ||
            exportEpoch != _authorizationEpoch ||
            _currentActor != exportActor)) {
      if (mounted) {
        setState(() {
          document = null;
          rows = [];
        });
      }
      throw StateError('Invoice authorization changed');
    }
    if (isOfflineHistoryInvoice(doc)) {
      final epoch = _authorizationEpoch;
      try {
        fresh = await reauthorizeOfflineInvoice(
          widget.client,
          doc['document_token'] as String,
        );
        if (!mounted || epoch != _authorizationEpoch) {
          throw StateError('Invoice authorization changed');
        }
        setState(() => document = fresh);
      } catch (_) {
        if (mounted) {
          setState(() {
            document = null;
            rows = [];
          });
        }
        rethrow;
      }
    }
    final bytes = await buildInvoicePdf(
      fresh,
      font.buffer.asUint8List(),
      logo.buffer.asUint8List(),
      paper: size ?? paper,
      reprint: reprint,
      arabic: arabic,
    );
    if (isOfflineHistoryInvoice(doc) &&
        (!mounted ||
            exportEpoch != _authorizationEpoch ||
            _currentActor != exportActor)) {
      if (mounted) {
        setState(() {
          document = null;
          rows = [];
        });
      }
      throw StateError('Invoice authorization changed');
    }
    return bytes;
  }

  Future<void> save() async {
    final typed = document != null && isOfflineHistoryInvoice(document!);
    final exportEpoch = _authorizationEpoch;
    try {
      final bytes = await pdf(document!);
      if (typed &&
          (!mounted ||
              exportEpoch != _authorizationEpoch ||
              document == null)) {
        throw StateError('Invoice authorization changed');
      }
      await FilePicker.saveFile(
        dialogTitle: 'Invoice PDF',
        fileName: '${invoiceNumber(document!)}.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
      );
      if (typed && mounted && exportEpoch != _authorizationEpoch) {
        setState(() {
          document = null;
          rows = [];
        });
      }
    } catch (_) {
      if (typed && mounted) {
        setState(() {
          document = null;
          rows = [];
        });
      }
      if (mounted) {
        setState(
          () => error = 'راجع إعداد رابط الفواتير وحاول مجددًا / Check the invoice website configuration',
        );
      }
    }
  }

  Future<void> printReceipt() async {
    if (busy || document == null) return;
    final printDocument = Map<String, dynamic>.from(document!);
    final actor = _currentActor;
    final epoch = _authorizationEpoch;
    final token = widget.client.auth.currentSession?.accessToken;
    bool authorized() =>
        mounted &&
        actor != null &&
        _currentActor == actor &&
        epoch == _authorizationEpoch &&
        widget.client.auth.currentSession?.accessToken == token;
    setState(() => busy = true);
    String? job, lease;
    var submissionUncertain = false;
    try {
      final rows = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_printers')
            .select()
            .eq('branch_id', printDocument['branch_id'])
            .eq('is_active', true)
            .order('is_default', ascending: false),
      );
      final targets = rows.map(InvoicePrintTarget.fromProfile).toList();
      if (targets.isEmpty || !authorized()) {
        throw StateError('Authorized printer required');
      }
      final store = PrinterDeviceStore();
      final preference = await store.read(actor!, printDocument['branch_id']);
      if (!mounted || !authorized()) {
        throw StateError('Invoice authorization changed');
      }
      final chosen = await chooseInvoicePrinter(
        context,
        targets,
        preferred: preference?.profileId,
        branchDefault: rows
            .where((r) => r['is_default'] == true)
            .firstOrNull?['printer_id'],
      );
      if (chosen == null) return;
      if (!authorized()) throw StateError('Invoice authorization changed');
      final direct =
          preference?.profileId == chosen.profileId &&
          preference?.direct == true;
      await store.save(actor, chosen, direct);
      if (!authorized()) throw StateError('Invoice authorization changed');
      job = await widget.client.rpc(
        'request_invoice_print',
        params: {
          'p_request': newOrderRequestId(),
          'p_invoice': printDocument['invoice_id'],
          'p_printer': chosen.profileId,
        },
      );
      final claim = Map<String, dynamic>.from(
        await widget.client.rpc('claim_invoice_print', params: {'p_job': job}),
      );
      lease = claim['lease_token'];
      final bytes = await pdf(
        Map<String, dynamic>.from(claim['invoice']),
        size: claim['paper'],
        reprint: claim['is_reprint'] == true,
      );
      if (!authorized()) throw StateError('Invoice authorization changed');
      final result = await (widget.printingService ?? InvoicePrintingService())
          .submit(
            bytes,
            chosen.withClaim(claim),
            documentName: 'Sabiha Hub ${invoiceNumber(printDocument)}',
            preferDirect: direct,
          );
      submissionUncertain =
          result.status == PrintSubmission.submitted ||
          result.status == PrintSubmission.unknown;
      await widget.client.rpc(
        'finish_invoice_print',
        params: {
          'p_job': job,
          'p_lease': lease,
          'p_outcome': result.status == PrintSubmission.submitted
              ? 'submitted'
              : 'failed',
          'p_error': result.status == PrintSubmission.submitted
              ? null
              : result.code,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (result.status) {
              PrintSubmission.submitted => customerText(
                context,
                'أُرسل المستند لخدمة النظام؛ تحقق من خروج الورق.',
                'Document submitted to OS service; check physical output.',
              ),
              PrintSubmission.cancelled => customerText(
                context,
                'أُلغيت الطباعة؛ لم تتغير المعاملة.',
                'Printing cancelled; payment unchanged.',
              ),
              PrintSubmission.unknown => customerText(
                context,
                'نتيجة الإرسال غير مؤكدة؛ افحص الطابعة قبل إعادة الطباعة.',
                'Submission is uncertain; check the printer before reprinting.',
              ),
              PrintSubmission.unavailable => customerText(
                context,
                'تعريف الطابعة أو الإرسال المحدد غير متاح. راجع إعدادات هذا الجهاز.',
                'Printer driver or selected submission mode is unavailable. Check device settings.',
              ),
            }),
          ),
        );
      }
    } catch (_) {
      if (job != null && lease != null) {
        try {
          await widget.client.rpc(
            'finish_invoice_print',
            params: {
              'p_job': job,
              'p_lease': lease,
              'p_outcome': 'failed',
              'p_error': submissionUncertain
                  ? 'device_submission_unknown'
                  : 'device_print_unavailable',
            },
          );
        } catch (_) {}
      }
      if (mounted) {
        setState(
          () => error = submissionUncertain
              ? customerText(
                  context,
                  'التحصيل محفوظ. تحقق من الطابعة قبل إعادة الطباعة؛ نتيجة الإرسال غير مؤكدة.',
                  'Payment is saved. Check the printer before reprinting; submission is uncertain.',
                )
              : customerText(
                  context,
                  'تعذرت الطباعة؛ التحصيل محفوظ. راجع الطابعة والصلاحيات.',
                  'Print failed; payment is saved. Check printer and permissions.',
                ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = document,
        snap = doc == null ? null : Map<String, dynamic>.from(doc['snapshot']);
    final String? selectedToken = doc == null
        ? null
        : doc['document_token'] as String?;
    return CustomerAdaptiveFrame(
      enabled: widget.role == 'customer',
      title: customerText(context, 'الفواتير الآمنة', 'Secure invoices'),
      selected: 2,
      appBar: AppBar(
        title: Text(customerText(context, 'الفواتير', 'Invoices')),
        actions: [
          if (widget.role != 'customer')
            IconButton(
              tooltip: customerText(
                context,
                'طباعة هذا الجهاز',
                'Printing on this device',
              ),
              icon: const Icon(Icons.print_outlined),
              onPressed: busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DevicePrinterSettingsScreen(
                          gateway: SupabaseDevicePrinterGateway(widget.client),
                        ),
                      ),
                    ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          TextField(
            controller: searchInput,
            onSubmitted: (_) => search(),
            decoration: InputDecoration(
              labelText: customerText(
                context,
                'رقم الفاتورة أو هاتف العميل',
                'Invoice number or customer phone',
              ),
              suffixIcon: IconButton(
                onPressed: search,
                tooltip: customerText(context, 'بحث', 'Search'),
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: Image.asset('assets/sabiha_brand_approved.png', height: 125),
          ),
          TextField(
            controller: input,
            decoration: const InputDecoration(
              labelText: 'رمز الفاتورة أو رابط QR / Invoice token or QR link',
            ),
          ),
          FilledButton(
            onPressed: busy ? null : () => open(input.text),
            child: const Text('فتح الفاتورة / Open Invoice'),
          ),
          if (widget.role != 'customer')
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('مسح QR / Scan QR'),
              onPressed: busy
                  ? null
                  : () async {
                      final result = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const InvoiceQrScannerScreen(),
                        ),
                      );
                      if (result != null && mounted) await open(result);
                    },
            ),
          if (rows.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey(selectedToken),
              isExpanded: true,
              initialValue:
                  rows.any((r) => r['document_token'] == selectedToken)
                  ? selectedToken
                  : null,
              items: rows
                  .map(
                    (r) => DropdownMenuItem(
                      value: r['document_token'] as String,
                      child: Text(
                        invoiceNumber(r),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: busy
                  ? null
                  : (v) {
                      if (v != null) open(v);
                    },
            ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          if (doc != null && snap != null) ...[
            if (widget.role == 'customer' &&
                !isOfflineHistoryInvoice(doc) &&
                doc['payment_status'] == 'unpaid')
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PaymentCheckoutScreen(
                      client: widget.client,
                      invoiceId: doc['invoice_id'],
                    ),
                  ),
                ),
                icon: const Icon(Icons.payments_outlined),
                label: Text(
                  customerText(
                    context,
                    'خيارات الدفع والأسعار',
                    'Payment options & prices',
                  ),
                ),
              ),
            Text(
              '${invoiceNumber(doc)}\n${invoiceDate(doc, Localizations.localeOf(context).languageCode == 'ar')}\n${invoiceState(doc['payment_status'], Localizations.localeOf(context).languageCode == 'ar')} · ${invoiceState(doc['payment_method'], Localizations.localeOf(context).languageCode == 'ar')}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: widget.role == 'customer' ? Colors.white : null,
              ),
            ),
            Text(
              '${snap['branch']['name_ar']} · ${snap['branch']['name_en']}\n${snap['branch']['address_ar']}',
            ),
            for (final row in List<Map<String, dynamic>>.from(snap['lines']))
              ListTile(
                title: Text('${row['name']}'),
                subtitle: Text('${row['quantity']} x ${row['unit_price']} EGP'),
                trailing: Text('${row['subtotal']} EGP'),
              ),
            Text(
              '${customerText(context, 'الخصم', 'Discount')}: ${snap['discount']} EGP\n${customerText(context, 'الإجمالي', 'Total')}: ${snap['total']} EGP\n${customerText(context, 'الخدمة', 'Service')}: ${invoiceState(doc['service_status'], Localizations.localeOf(context).languageCode == 'ar')}',
            ),
            if (snap['loyalty'] is Map)
              Text(
                '${customerText(context, 'خصم الولاء', 'Loyalty discount')}: ${(snap['loyalty'] as Map)['payable_discount']} EGP · ${(snap['loyalty'] as Map)['points']} ${customerText(context, 'نقطة', 'points')}',
              ),
            if (snap['visit_loyalty'] is Map)
              Text(
                '${customerText(context, 'خصم مكافأة الزيارات', 'Visit reward discount')}: ${(snap['visit_loyalty'] as Map)['payable_discount']} EGP · ${(snap['visit_loyalty'] as Map)['visits_redeemed']} ${customerText(context, 'زيارة', 'visits')}',
              ),
            Text(
              isOfflineHistoryInvoice(doc)
                  ? 'الضريبة غير مسجلة / Tax not recorded'
                  : 'الضريبة غير مسجلة في الفاتورة القديمة / Tax not recorded in legacy invoice',
            ),
            DropdownButtonFormField<String>(
              initialValue: paper,
              items: ['A4', '80', '58']
                  .map(
                    (x) => DropdownMenuItem(
                      value: x,
                      child: Text(x == 'A4' ? x : '$x mm'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => paper = v);
              },
            ),
            FilledButton(
              onPressed: busy ? null : save,
              child: const Text('تنزيل PDF مع QR / Download PDF with QR'),
            ),
            if (widget.role == 'customer' && !isOfflineHistoryInvoice(doc))
              InvoiceReviewPanel(
                key: ValueKey(doc['document_token']),
                client: widget.client,
                document: doc,
              ),
            if (widget.role != 'customer')
              OutlinedButton(
                onPressed: busy ? null : printReceipt,
                child: Text(
                  customerText(
                    context,
                    'طباعة / إعادة طباعة',
                    'Print / reprint',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class InvoiceQrScannerScreen extends StatefulWidget {
  const InvoiceQrScannerScreen({super.key});
  @override
  State<InvoiceQrScannerScreen> createState() => _InvoiceQrScannerScreenState();
}

class _InvoiceQrScannerScreenState extends State<InvoiceQrScannerScreen> {
  final controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool found = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('مسح الفاتورة / Scan Invoice')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'المسح يفتح الفاتورة بعد التحقق من صلاحيتك؛ لا ينشئ دفعة. / Scanning only opens an authorized invoice; it never records payment.',
          ),
        ),
        Expanded(
          child: MobileScanner(
            controller: controller,
            onDetect: (capture) {
              if (found) return;
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue;
                if (value != null && invoiceTokenFromInput(value) != null) {
                  found = true;
                  controller.stop();
                  Navigator.pop(context, value);
                  return;
                }
              }
            },
          ),
        ),
      ],
    ),
  );
}

class PrinterSettingsScreen extends StatefulWidget {
  final SupabaseClient client;
  const PrinterSettingsScreen({super.key, required this.client});
  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  List<Map<String, dynamic>> branches = [], printers = [];
  String? branch;
  String? error;
  bool deviceAuto = false;
  final portalOrigin = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      deviceAuto = prefs.getBool('invoice_device_auto_print') ?? false;
      final settings = await widget.client
          .from('business_invoice_portal_settings')
          .select('public_origin')
          .eq('id', true)
          .single();
      portalOrigin.text = settings['public_origin'];
      final b = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_branches')
            .select('branch_id,name_ar,name_en,is_default')
            .order('is_default', ascending: false),
      );
      if (!AppConfig.multiBranchEnabled) {
        branch = b
            .where((r) => r['is_default'] == true)
            .firstOrNull?['branch_id'];
      }
      branch ??= AppConfig.multiBranchEnabled && b.isNotEmpty
          ? b.first['branch_id']
          : null;
      final p = branch == null
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await widget.client
                  .from('business_printers')
                  .select()
                  .eq('branch_id', branch!),
            );
      if (mounted) {
        setState(() {
          branches = b;
          printers = p;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = customerText(
            context,
            'يلزم حساب المالك الحالي.',
            'A current owner account is required.',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    portalOrigin.dispose();
    super.dispose();
  }

  Future<void> edit([Map<String, dynamic>? printer]) async {
    if (branch == null) return;
    final name = TextEditingController(text: printer?['name'] ?? ''),
        identifier = TextEditingController(
          text: printer?['device_identifier'] ?? '',
        );
    var paper = printer?['paper'] as String? ?? 'A4',
        transport = printer?['transport'] as String? ?? 'system',
        active = printer?['is_active'] as bool? ?? true,
        auto = printer?['auto_print'] as bool? ?? false,
        defaultPrinter = printer?['is_default'] as bool? ?? printers.isEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(
            customerText(c, 'إعداد ملف الطابعة', 'Printer profile setup'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: customerText(c, 'اسم الطابعة', 'Printer name'),
                  ),
                ),
                TextField(
                  controller: identifier,
                  decoration: InputDecoration(
                    labelText: customerText(
                      c,
                      'اسم أو معرّف الطابعة المثبتة بالنظام',
                      'Installed OS printer name or identifier',
                    ),
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: transport,
                  decoration: InputDecoration(
                    labelText: customerText(
                      c,
                      'طريقة الاتصال عبر تعريف النظام',
                      'Connection through system driver',
                    ),
                  ),
                  items:
                      const {
                            'system': PrinterConnection.system,
                            'usb': PrinterConnection.usb,
                            'bluetooth': PrinterConnection.bluetooth,
                            'wifi': PrinterConnection.wifi,
                            'network': PrinterConnection.lan,
                          }.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(printerConnectionLabel(c, e.value)),
                            ),
                          )
                          .toList(),
                  isExpanded: true,
                  onChanged: (v) {
                    if (v != null) set(() => transport = v);
                  },
                ),
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    labelText: customerText(c, 'مقاس الورق', 'Paper size'),
                  ),
                  initialValue: paper,
                  items: ['A4', '80', '58']
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (s) {
                    if (s != null) set(() => paper = s);
                  },
                ),
                SwitchListTile(
                  title: Text(customerText(c, 'مفعلة', 'Active')),
                  value: active,
                  onChanged: (v) => set(() => active = v),
                ),
                SwitchListTile(
                  title: Text(
                    customerText(c, 'تلقائية بعد الدفع', 'Auto after payment'),
                  ),
                  value: auto,
                  onChanged: (v) => set(() => auto = v),
                ),
                SwitchListTile(
                  title: Text(
                    customerText(c, 'افتراضية للفرع', 'Branch default'),
                  ),
                  value: defaultPrinter,
                  onChanged: (v) => set(() => defaultPrinter = v),
                ),
                Text(
                  customerText(
                    c,
                    'أوقف الافتراضية السابقة قبل اختيار أخرى. طرق الاتصال تعتمد على تعريف متوافق، وليست دعمًا مباشرًا عامًا من التطبيق.',
                    'Unset the previous default before selecting another. Connections require compatible drivers, not generic raw device access.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(customerText(c, 'إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(customerText(c, 'حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        final values = {
          'branch_id': branch,
          'name': name.text.trim(),
          'device_identifier': identifier.text.trim(),
          'paper': paper,
          'transport': transport,
          'is_active': active,
          'auto_print': auto,
          'is_default': defaultPrinter,
        };
        if (printer == null) {
          await widget.client.from('business_printers').insert(values);
        } else {
          await widget.client
              .from('business_printers')
              .update(values)
              .eq('printer_id', printer['printer_id']);
        }
        await load();
      } catch (_) {
        if (mounted) {
          setState(
            () => error = customerText(
              context,
              'راجع صلاحيات المالك والاسم والطابعة الافتراضية.',
              'Check owner permission, name and unique branch default.',
            ),
          );
        }
      }
    }
    name.dispose();
    identifier.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        customerText(
          context,
          'ملفات الطابعات وإعداداتها',
          'Printer profiles and settings',
        ),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        TextField(
          controller: portalOrigin,
          decoration: InputDecoration(
            labelText: customerText(
              context,
              'رابط موقع الفواتير',
              'Invoice website origin',
            ),
          ),
        ),
        OutlinedButton(
          onPressed: () async {
            try {
              await widget.client
                  .from('business_invoice_portal_settings')
                  .update({
                    'public_origin': portalOrigin.text.trim().replaceFirst(
                      RegExp(r'/$'),
                      '',
                    ),
                  })
                  .eq('id', true);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      customerText(context, 'تم حفظ الرابط.', 'Origin saved.'),
                    ),
                  ),
                );
              }
            } catch (_) {
              if (mounted) {
                setState(
                  () => error = customerText(
                    context,
                    'يلزم رابط HTTPS صالح دون مسار.',
                    'A valid HTTPS origin without a path is required.',
                  ),
                );
              }
            }
          },
          child: Text(customerText(context, 'حفظ الرابط', 'Save origin')),
        ),
        SwitchListTile(
          title: Text(
            customerText(
              context,
              'تشغيل الطباعة التلقائية على هذا الجهاز',
              'Enable auto print on this device',
            ),
          ),
          subtitle: Text(
            customerText(
              context,
              'تتبع الطباعة التلقائية ملف الطابعة المثبت بطلب الطباعة. قد يظهر حوار تأكيد النظام.',
              'Automatic printing uses the job’s assigned printer profile. The system may show a confirmation dialog.',
            ),
          ),
          value: deviceAuto,
          onChanged: (v) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('invoice_device_auto_print', v);
            if (mounted) setState(() => deviceAuto = v);
          },
        ),
        if (AppConfig.multiBranchEnabled)
          DropdownButtonFormField<String>(
            initialValue: branch,
            items: branches
                .map(
                  (b) => DropdownMenuItem(
                    value: b['branch_id'] as String,
                    child: Text('${b['name_ar']} · ${b['name_en']}'),
                  ),
                )
                .toList(),
            onChanged: (v) {
              setState(() => branch = v);
              load();
            },
          ),
        Text(
          customerText(
            context,
            'A4 · 58 mm · 80 mm\nUSB / Bluetooth / Wi-Fi / LAN عبر تعريف أو خدمة نظام متوافقة فقط. يلزم اختبار فعلي قبل اعتماد أي اتصال أو قص ورق.',
            'A4 · 58 mm · 80 mm\nUSB / Bluetooth / Wi-Fi / LAN require compatible OS drivers/services. Physical connection and cutting require real-printer testing.',
          ),
        ),
        for (final p in printers)
          Card(
            child: ListTile(
              title: Text('${p['name']} · ${p['paper']}'),
              subtitle: Text(
                '${customerText(context, 'تلقائية', 'Automatic')}: ${p['auto_print'] == true ? customerText(context, 'نعم', 'Yes') : customerText(context, 'لا', 'No')} · ${customerText(context, 'افتراضية', 'Default')}: ${p['is_default'] == true ? customerText(context, 'نعم', 'Yes') : customerText(context, 'لا', 'No')}',
              ),
              onTap: () => edit(p),
            ),
          ),
        OutlinedButton.icon(
          icon: const Icon(Icons.print_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DevicePrinterSettingsScreen(
                gateway: SupabaseDevicePrinterGateway(widget.client),
              ),
            ),
          ),
          label: Text(
            customerText(
              context,
              'اختيار طابعة هذا الجهاز واختبارها',
              'Choose and test this device’s printer',
            ),
          ),
        ),
        FilledButton(
          onPressed: () => edit(),
          child: Text(
            customerText(context, 'إضافة ملف طابعة', 'Add printer profile'),
          ),
        ),
      ],
    ),
  );
}

/// Called only after the payment RPC has committed. This function never collects
/// money and all failures are isolated from the original payment result.
Future<void> autoPrintCommittedPayment(
  SupabaseClient client,
  String paymentId, {
  InvoicePrintingService? printingService,
}) async {
  final actor = client.auth.currentUser?.id;
  final token = client.auth.currentSession?.accessToken;
  bool authorized() =>
      actor != null &&
      token != null &&
      client.auth.currentUser?.id == actor &&
      client.auth.currentSession?.accessToken == token;
  if (!authorized()) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('invoice_device_auto_print') ?? false) ||
        !authorized()) {
      return;
    }
    final jobs = List<Map<String, dynamic>>.from(
      await client
          .from('business_print_jobs')
          .select('job_id,printer_id,branch_id')
          .eq('payment_id', paymentId)
          .eq('status', 'pending'),
    );
    for (final job in jobs) {
      if (!authorized()) return;
      Map<String, dynamic>? claim;
      var uncertain = false;
      try {
        claim = Map<String, dynamic>.from(
          await client.rpc(
            'claim_invoice_print',
            params: {'p_job': job['job_id']},
          ),
        );
        final font = await rootBundle.load(
              'assets/NotoNaskhArabic-Regular.ttf',
            ),
            logo = await rootBundle.load('assets/sabiha_brand_approved.png');
        final bytes = await buildInvoicePdf(
          Map<String, dynamic>.from(claim['invoice']),
          font.buffer.asUint8List(),
          logo.buffer.asUint8List(),
          paper: claim['paper'],
          reprint: claim['is_reprint'] == true,
          arabic: prefs.getString('app_language') != 'en',
        );
        if (!authorized()) throw StateError('Print authorization changed');
        final target = InvoicePrintTarget.fromProfile({
          'printer_id': job['printer_id'],
          'branch_id': job['branch_id'],
          'name': 'Sabiha Hub',
          'paper': claim['paper'],
          'transport': claim['transport'],
          'device_identifier': claim['device_identifier'],
        });
        final preference = await PrinterDeviceStore().read(
          actor!,
          target.branchId,
        );
        if (!authorized()) throw StateError('Print authorization changed');
        final result = await (printingService ?? InvoicePrintingService()).submit(
          bytes,
          target,
          documentName:
              'Sabiha Hub ${invoiceNumber(Map<String, dynamic>.from(claim['invoice']))}',
          preferDirect:
              preference?.profileId == target.profileId &&
              preference?.direct == true,
        );
        final submitted = result.status == PrintSubmission.submitted;
        uncertain = submitted || result.status == PrintSubmission.unknown;
        await client.rpc(
          'finish_invoice_print',
          params: {
            'p_job': job['job_id'],
            'p_lease': claim['lease_token'],
            'p_outcome': submitted ? 'submitted' : 'failed',
            'p_error': submitted ? null : result.code,
          },
        );
      } catch (_) {
        if (claim != null) {
          try {
            await client.rpc(
              'finish_invoice_print',
              params: {
                'p_job': job['job_id'],
                'p_lease': claim['lease_token'],
                'p_outcome': 'failed',
                'p_error': uncertain
                    ? 'device_submission_unknown'
                    : 'device_print_unavailable',
              },
            );
          } catch (_) {}
        }
      }
    }
  } catch (_) {
    /* Payment is already committed. Queue/retry remains authoritative. */
  }
}

class InvoiceReviewPanel extends StatefulWidget {
  final SupabaseClient client;
  final Map<String, dynamic> document;
  const InvoiceReviewPanel({
    super.key,
    required this.client,
    required this.document,
  });
  @override
  State<InvoiceReviewPanel> createState() => _InvoiceReviewPanelState();
}

class _InvoiceReviewPanelState extends State<InvoiceReviewPanel> {
  late Future<Map<String, dynamic>> contextFuture;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  void refresh() {
    contextFuture = widget.client
        .rpc(
          'invoice_review_context',
          params: {'p_token': widget.document['document_token']},
        )
        .then((v) => Map<String, dynamic>.from(v));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: contextFuture,
    builder: (c, s) {
      if (s.hasError) {
        return const Text('تعذر تحميل التقييم / Unable to load reviews');
      }
      if (!s.hasData) return const LinearProgressIndicator();
      final data = s.data!;
      if (data['can_review'] != true) {
        return const Text(
          'التقييم بعد اكتمال خدمتك فقط / Reviews are available after your service is completed',
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('تقييم الخدمة والموظفين / Service & Staff Reviews'),
          const Text(
            'التعديل متاح 7 أيام من أول تقييم، والتعليقات تخضع للمراجعة. / Edits are allowed for 7 days; comments are moderated.',
          ),
          InvoiceReviewForm(
            key: ValueKey('overall_${widget.document['document_token']}'),
            client: widget.client,
            token: widget.document['document_token'],
            booking: data['booking_id'],
            initialStars: (data['stars'] as num?)?.toInt() ?? 5,
            initialComment: data['comment'] ?? '',
            editable: data['editable'] == true,
            title: 'تقييم الخدمة / Service Rating',
            onSaved: () {
              setState(refresh);
            },
          ),
          for (final employee in List<Map<String, dynamic>>.from(
            data['employees'] ?? [],
          ))
            InvoiceReviewForm(
              key: ValueKey(employee['employee_id']),
              client: widget.client,
              token: widget.document['document_token'],
              booking: data['booking_id'],
              employee: employee['employee_id'],
              initialStars: (employee['stars'] as num?)?.toInt() ?? 5,
              initialComment: employee['comment'] ?? '',
              editable: employee['editable'] == true,
              title: employee['display_name'],
              onSaved: () {
                setState(refresh);
              },
            ),
        ],
      );
    },
  );
}

class InvoiceReviewForm extends StatefulWidget {
  final SupabaseClient client;
  final String token, booking, title, initialComment;
  final String? employee;
  final int initialStars;
  final bool editable;
  final VoidCallback onSaved;
  const InvoiceReviewForm({
    super.key,
    required this.client,
    required this.token,
    required this.booking,
    required this.title,
    required this.initialComment,
    required this.initialStars,
    required this.editable,
    required this.onSaved,
    this.employee,
  });
  @override
  State<InvoiceReviewForm> createState() => _InvoiceReviewFormState();
}

class _InvoiceReviewFormState extends State<InvoiceReviewForm> {
  late int stars;
  late TextEditingController comment;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    stars = widget.initialStars;
    comment = TextEditingController(text: widget.initialComment);
  }

  @override
  void dispose() {
    comment.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      if (widget.employee == null) {
        await widget.client.rpc(
          'save_invoice_service_review',
          params: {
            'p_token': widget.token,
            'p_stars': stars,
            'p_comment': comment.text.trim(),
          },
        );
      } else {
        await widget.client.rpc(
          'save_service_review',
          params: {
            'p_booking': widget.booking,
            'p_employee': widget.employee,
            'p_stars': stars,
            'p_comment': comment.text.trim(),
          },
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ التقييم / Review saved')),
        );
        widget.onSaved();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'تعذر حفظ التقييم؛ راجع اكتمال الخدمة وفترة التعديل / Check completed service and edit window',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Text(widget.title),
          Slider(
            value: stars.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            label: '$stars ★',
            onChanged: widget.editable && !busy
                ? (v) => setState(() => stars = v.toInt())
                : null,
          ),
          TextField(
            controller: comment,
            maxLength: 1000,
            maxLines: 3,
            enabled: widget.editable && !busy,
            decoration: const InputDecoration(
              labelText: 'تعليق اختياري / Optional comment',
            ),
          ),
          if (error != null) Text(error!),
          FilledButton(
            onPressed: widget.editable && !busy ? save : null,
            child: const Text('حفظ التقييم / Save Review'),
          ),
        ],
      ),
    ),
  );
}

class ServiceReviewAdminScreen extends StatefulWidget {
  final SupabaseClient client;
  const ServiceReviewAdminScreen({super.key, required this.client});
  @override
  State<ServiceReviewAdminScreen> createState() =>
      _ServiceReviewAdminScreenState();
}

class _ServiceReviewAdminScreenState extends State<ServiceReviewAdminScreen> {
  late Future<List<Map<String, dynamic>>> future;
  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    future = widget.client
        .from('completed_service_reviews')
        .select()
        .order('created_at', ascending: false)
        .limit(100)
        .then((v) => List<Map<String, dynamic>>.from(v));
  }

  Future<void> moderate(Map<String, dynamic> review) async {
    final reason = TextEditingController();
    bool publish = review['comment_published'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('مراجعة التعليق / Moderate Comment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${review['stars']} ★ · ${review['comment']}'),
              SwitchListTile(
                title: const Text('نشر التعليق / Publish Comment'),
                value: publish,
                onChanged: (v) => set(() => publish = v),
              ),
              TextField(
                controller: reason,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'سبب المراجعة / Reason',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('إلغاء / Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('حفظ / Save'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.client.rpc(
          'moderate_invoice_service_review',
          params: {
            'p_review': review['review_id'],
            'p_publish': publish,
            'p_reason': reason.text.trim(),
          },
        );
        if (mounted) setState(load);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'يلزم حساب المالك وسبب واضح للمراجعة / Owner permission and a clear reason are required',
              ),
            ),
          );
        }
      }
    }
    reason.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تقييمات الخدمات / Service Reviews')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (c, s) {
        if (s.hasError) {
          return const Center(
            child: Text('تعذر تحميل التقييمات / Unable to load reviews'),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'إخفاء التعليق لا يغيّر النجوم. / Hiding a comment never changes the stars.',
            ),
            for (final r in s.data!)
              Card(
                child: ListTile(
                  title: Text('${r['stars']} ★ · ${r['invoice_id']}'),
                  subtitle: Text('${r['comment']}'),
                  trailing: Icon(
                    r['comment_published'] == true
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  onTap: () => moderate(r),
                ),
              ),
          ],
        );
      },
    ),
  );
}
