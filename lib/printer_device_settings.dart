import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' show PdfColor;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoice_printing.dart';

String _t(BuildContext c, String ar, String en) =>
    Localizations.localeOf(c).languageCode == 'en' ? en : ar;
String printerConnectionLabel(BuildContext c, PrinterConnection connection) =>
    switch (connection) {
      PrinterConnection.system => _t(
        c,
        'خدمة طباعة النظام',
        'System print service',
      ),
      PrinterConnection.usb => _t(
        c,
        'USB عبر تعريف النظام',
        'USB through OS driver',
      ),
      PrinterConnection.bluetooth => _t(
        c,
        'Bluetooth عبر تعريف متوافق',
        'Bluetooth through compatible driver',
      ),
      PrinterConnection.wifi => _t(
        c,
        'Wi-Fi عبر خدمة النظام',
        'Wi-Fi through OS service',
      ),
      PrinterConnection.lan => _t(
        c,
        'LAN عبر تعريف الشبكة',
        'LAN through network driver',
      ),
    };

class PrinterDevicePreference {
  const PrinterDevicePreference(this.profileId, this.direct);
  final String profileId;
  final bool direct;
}

class PrinterDeviceStore {
  String key(String actor, String branch) => 'invoice_printer_${actor}_$branch';
  Future<PrinterDevicePreference?> read(String actor, String branch) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key(actor, branch));
    if (raw == null || raw.length > 240) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 3 ||
          value['version'] != 1 ||
          value['profile_id'] is! String ||
          value['direct'] is! bool ||
          !RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
          ).hasMatch(value['profile_id'])) {
        return null;
      }
      return PrinterDevicePreference(value['profile_id'], value['direct']);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(
    String actor,
    InvoicePrintTarget target,
    bool direct,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    // One atomic preference value; a partial save cannot inherit direct mode from another printer.
    if (!await prefs.setString(
      key(actor, target.branchId),
      jsonEncode({
        'version': 1,
        'profile_id': target.profileId,
        'direct': direct,
      }),
    )) {
      throw StateError('Printer preference not saved');
    }
  }
}

Future<InvoicePrintTarget?> chooseInvoicePrinter(
  BuildContext context,
  List<InvoicePrintTarget> targets, {
  String? preferred,
  String? branchDefault,
}) async {
  if (targets.isEmpty) return null;
  var selected =
      targets.where((t) => t.profileId == preferred).firstOrNull ??
      targets.where((t) => t.profileId == branchDefault).firstOrNull;
  return showDialog<InvoicePrintTarget>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, set) => AlertDialog(
        title: Text(
          _t(dialog, 'اختيار الطابعة والورق', 'Choose printer and paper'),
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: selected?.profileId,
                  decoration: InputDecoration(
                    labelText: _t(dialog, 'ملف الطابعة', 'Printer profile'),
                  ),
                  items: targets
                      .map(
                        (t) => DropdownMenuItem(
                          value: t.profileId,
                          child: Text('${t.name} · ${t.paper}'),
                        ),
                      )
                      .toList(),
                  onChanged: (id) => set(
                    () => selected = targets
                        .where((t) => t.profileId == id)
                        .firstOrNull,
                  ),
                ),
                if (selected != null) ...[
                  const SizedBox(height: 12),
                  Text(printerConnectionLabel(dialog, selected!.connection)),
                ],
                const SizedBox(height: 12),
                Text(
                  _t(
                    dialog,
                    'يحدد ملف الطابعة مقاس PDF. قد يطلب النظام اختيار الطابعة والورق مجددًا. الاتصال والطباعة الفعلية يعتمدان على الجهاز والتعريف؛ لا يُفترض دعم Bluetooth أو USB المباشر من المتصفح.',
                    'The profile sets PDF paper size. The system may ask you to choose printer and paper again. Actual connection/output depends on the device and driver; direct browser Bluetooth or USB is not assumed.',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_t(dialog, 'إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: selected == null
                ? null
                : () => Navigator.pop(dialog, selected),
            child: Text(_t(dialog, 'متابعة للطباعة', 'Continue to print')),
          ),
        ],
      ),
    ),
  );
}

/// Clearly labelled diagnostic page, not an invoice and not an ETA document.
Future<Uint8List> buildPrinterDiagnosticPage(
  InvoicePrintTarget target, {
  Future<ByteData> Function(String)? loadAsset,
}) async {
  final load = loadAsset ?? rootBundle.load;
  final font = await load('assets/NotoNaskhArabic-Regular.ttf');
  final logo = await load('assets/sabiha_brand_approved.png');
  final doc = pw.Document();
  final arabic = pw.Font.ttf(font);
  doc.addPage(
    pw.Page(
      pageFormat: target.format,
      theme: pw.ThemeData.withFont(
        base: arabic,
        fontFallback: [pw.Font.helvetica()],
      ),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Image(
            pw.MemoryImage(logo.buffer.asUint8List()),
            width: 64,
            height: 64,
            fit: pw.BoxFit.contain,
          ),
          pw.Text(
            'Sabiha Hub',
            style: pw.TextStyle(font: pw.Font.helveticaBold(), fontSize: 15),
          ),
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Text(
              'اختبار الطابعة - ليس فاتورة',
              style: const pw.TextStyle(fontSize: 12),
            ),
          ),
          pw.Text(
            'PRINTER TEST - NOT AN INVOICE',
            style: pw.TextStyle(font: pw.Font.helvetica(), fontSize: 8),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'A4 / 58 / 80 mm · ${target.paper}',
            style: pw.TextStyle(font: pw.Font.helvetica(), fontSize: 9),
          ),
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Text(
              'وضوح العربية والأرقام: ١٢٣٤٥٦٧٨٩٠',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ),
          pw.Text(
            'English and digits: 0123456789',
            style: pw.TextStyle(font: pw.Font.helvetica(), fontSize: 9),
          ),
          pw.SizedBox(height: 8),
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: 'sabiha-hub:printer-test:v1:paper=${target.paper}',
            width: 64,
            height: 64,
          ),
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Text(
              'رمز اختبار داخلي فقط',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ),
          pw.Text(
            'Internal test QR only',
            style: pw.TextStyle(font: pw.Font.helvetica(), fontSize: 8),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            width: 113.3858,
            height: 1,
            color: const PdfColor.fromInt(0xff101820),
          ),
          pw.Text(
            '40 mm - verify physical scale and cutter manually',
            style: pw.TextStyle(font: pw.Font.helvetica(), fontSize: 7),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

abstract class DevicePrinterGateway {
  String get actor;
  Future<String> branch();
  Future<List<Map<String, dynamic>>> profiles(String branch);
}

class SupabaseDevicePrinterGateway implements DevicePrinterGateway {
  SupabaseDevicePrinterGateway(this.client)
    : actor = client.auth.currentUser?.id ?? '',
      token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  @override
  final String actor;
  final String? token;
  bool get valid =>
      actor.isNotEmpty &&
      token != null &&
      client.auth.currentUser?.id == actor &&
      client.auth.currentSession?.accessToken == token;
  void check() {
    if (!valid) throw StateError('Printer authorization changed');
  }

  @override
  Future<String> branch() async {
    check();
    final value = await client.rpc('default_branch_id');
    check();
    return value as String;
  }

  @override
  Future<List<Map<String, dynamic>>> profiles(String branch) async {
    check();
    final value = await client
        .from('business_printers')
        .select()
        .eq('branch_id', branch)
        .eq('is_active', true)
        .order('is_default', ascending: false);
    check();
    return List<Map<String, dynamic>>.from(value);
  }
}

class DevicePrinterSettingsScreen extends StatefulWidget {
  const DevicePrinterSettingsScreen({
    super.key,
    required this.gateway,
    this.driver,
    this.printingService,
    this.store,
    this.diagnosticBuilder,
  });
  final DevicePrinterGateway gateway;
  final SystemPrintDriver? driver;
  final InvoicePrintingService? printingService;
  final PrinterDeviceStore? store;
  final Future<Uint8List> Function(InvoicePrintTarget)? diagnosticBuilder;
  @override
  State<DevicePrinterSettingsScreen> createState() =>
      _DevicePrinterSettingsScreenState();
}

class _DevicePrinterSettingsScreenState
    extends State<DevicePrinterSettingsScreen> {
  late final SystemPrintDriver driver =
      widget.driver ?? PluginSystemPrintDriver();
  late final PrinterDeviceStore store = widget.store ?? PrinterDeviceStore();
  List<InvoicePrintTarget> targets = [];
  InvoicePrintTarget? selected;
  PrintingInfo? capabilities;
  String? branch, paper, transport, error, message;
  bool direct = false, busy = true;
  int epoch = 0;
  StreamSubscription<AuthState>? auth;
  @override
  void initState() {
    super.initState();
    watch();
    unawaited(load());
  }

  void watch() {
    auth?.cancel();
    final g = widget.gateway;
    if (g is SupabaseDevicePrinterGateway) {
      auth = g.client.auth.onAuthStateChange.listen((_) {
        if (!g.valid && mounted) {
          epoch++;
          setState(() {
            targets = [];
            selected = null;
            busy = false;
            error = 'authorization';
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant DevicePrinterSettingsScreen old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway) {
      epoch++;
      watch();
      unawaited(load());
    }
  }

  @override
  void dispose() {
    epoch++;
    auth?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final scope = ++epoch;
    final gateway = widget.gateway;
    setState(() {
      busy = true;
      error = null;
      message = null;
      targets = [];
      selected = null;
    });
    try {
      final b = await gateway.branch();
      final rows = await gateway.profiles(b);
      final actual = rows.map(InvoicePrintTarget.fromProfile).toList();
      if (actual.any((t) => t.branchId != b)) {
        throw StateError('Wrong printer branch');
      }
      PrintingInfo info;
      try {
        info = await driver.capabilities();
      } catch (_) {
        info = PrintingInfo.unavailable;
      }
      final pref = await store.read(gateway.actor, b);
      final pick =
          actual.where((t) => t.profileId == pref?.profileId).firstOrNull ??
          actual
              .where(
                (t) => rows.any(
                  (r) =>
                      r['printer_id'] == t.profileId && r['is_default'] == true,
                ),
              )
              .firstOrNull;
      if (!mounted || scope != epoch) return;
      setState(() {
        branch = b;
        targets = actual;
        selected = pick;
        paper = pick?.paper;
        transport = pick?.transport;
        capabilities = info;
        direct =
            pref?.direct == true && info.directPrint && info.canListPrinters;
        busy = false;
      });
    } catch (_) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          error = 'load';
        });
      }
    }
  }

  Future<void> save() async {
    if (busy || selected == null || branch == null) return;
    final scope = epoch, gateway = widget.gateway;
    final chosen = selected!, requestedDirect = direct;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final fresh = await gateway.profiles(chosen.branchId);
      if (!mounted || scope != epoch || gateway != widget.gateway) return;
      if (!fresh.any(
        (r) =>
            r['printer_id'] == chosen.profileId &&
            r['paper'] == chosen.paper &&
            r['transport'] == chosen.transport,
      )) {
        throw StateError('Printer profile changed');
      }
      await store.save(gateway.actor, chosen, requestedDirect);
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          message = 'saved';
        });
      }
    } catch (_) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          error = 'save';
          targets = [];
          selected = null;
        });
      }
    }
  }

  Future<void> test() async {
    if (busy || selected == null) return;
    final chosen = selected!;
    final scope = epoch, gateway = widget.gateway;
    final requestedDirect = direct;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_t(c, 'تأكيد اختبار الطابعة', 'Confirm printer test')),
        content: Text(
          '${chosen.name} · ${chosen.paper}\n${_t(c, 'سيتم إرسال صفحة اختبار فقط، دون فاتورة أو تحصيل. اختبر المقاس والقص ووضوح العربية وQR على الطابعة الفعلية.', 'Sends a diagnostic page only, with no invoice or payment. Check actual paper, cutting, Arabic and QR on the physical printer.')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(_t(c, 'إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(_t(c, 'طباعة الاختبار', 'Print test')),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        scope != epoch ||
        gateway != widget.gateway) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final fresh = await gateway.profiles(chosen.branchId);
      final profile = fresh
          .where((r) => r['printer_id'] == chosen.profileId)
          .firstOrNull;
      if (profile == null) throw StateError('Printer unavailable');
      final actual = InvoicePrintTarget.fromProfile(profile);
      final bytes =
          await (widget.diagnosticBuilder ?? buildPrinterDiagnosticPage)(
            actual,
          );
      if (!mounted || scope != epoch) return;
      final result =
          await (widget.printingService ??
                  InvoicePrintingService(
                    adapters: [SystemInvoicePrinterAdapter(driver: driver)],
                  ))
              .submit(
                bytes,
                actual,
                documentName: 'Sabiha Hub printer test',
                preferDirect: requestedDirect,
              );
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          message = result.status.name;
        });
      }
    } catch (_) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          error = 'test';
          targets = [];
          selected = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_t(context, 'طباعة هذا الجهاز', 'Printing on this device')),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(
            _t(
              context,
              'تعذر إكمال إعداد الطباعة. راجع الجلسة والصلاحيات والطابعة المتاحة.',
              'Could not complete print setup. Check session, permissions and available printer.',
            ),
          ),
        if (message != null)
          Text(switch (message) {
            'saved' => _t(
              context,
              'حُفظ الاختيار لهذا المستخدم والجهاز.',
              'Choice saved for this user and device.',
            ),
            'submitted' => _t(
              context,
              'أُرسلت الصفحة إلى خدمة النظام؛ لم يُتحقق من خروج الورق.',
              'Page submitted to OS service; physical output is not verified.',
            ),
            'cancelled' => _t(
              context,
              'أُلغي الاختبار دون فاتورة أو دفع.',
              'Test cancelled; no invoice or payment.',
            ),
            'unknown' => _t(
              context,
              'نتيجة الإرسال غير مؤكدة. افحص الطابعة قبل إعادة الطباعة.',
              'Submission outcome is uncertain. Check the printer before reprinting.',
            ),
            _ => _t(
              context,
              'خدمة الطباعة أو الاتصال المحدد غير متاحين على هذا الجهاز.',
              'Print service or selected connection is unavailable on this device.',
            ),
          }),
        Text(
          _t(
            context,
            'اختر من ملفات الطابعات النشطة التي أعدها المالك. هذا الإعداد محلي؛ لا يغير الطابعة الافتراضية العامة.',
            'Choose an active printer profile configured by the owner. This local setting does not change the branch default.',
          ),
        ),
        if (targets.isEmpty && !busy)
          Text(
            _t(
              context,
              'لا توجد طابعات نشطة مصرح بها. يضيف المالك ملفات الطابعات أولًا.',
              'No authorized active printers. The owner must configure profiles first.',
            ),
          ),
        if (targets.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('paper-$paper'),
            initialValue: paper,
            decoration: InputDecoration(
              labelText: _t(
                context,
                'مقاس الورق المتاح',
                'Available paper size',
              ),
            ),
            items: targets
                .map((t) => t.paper)
                .toSet()
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(v == 'A4' ? 'A4' : '$v mm'),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (v) => setState(() {
                    paper = v;
                    transport = null;
                    selected = null;
                  }),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('transport-$paper-$transport'),
            isExpanded: true,
            initialValue: transport,
            decoration: InputDecoration(
              labelText: _t(
                context,
                'طريقة الاتصال المتاحة',
                'Available connection',
              ),
            ),
            items: targets
                .where((t) => paper == null || t.paper == paper)
                .map((t) => t.transport)
                .toSet()
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(
                      printerConnectionLabel(
                        context,
                        targets
                            .firstWhere((t) => t.transport == value)
                            .connection,
                      ),
                    ),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (value) => setState(() {
                    transport = value;
                    selected = null;
                  }),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('printer-$paper-$transport-${selected?.profileId}'),
            isExpanded: true,
            initialValue: selected?.profileId,
            decoration: InputDecoration(
              labelText: _t(
                context,
                'الطابعة الافتراضية لهذا الجهاز',
                'Default printer for this device',
              ),
            ),
            items: targets
                .where(
                  (t) =>
                      (paper == null || t.paper == paper) &&
                      (transport == null || t.transport == transport),
                )
                .map(
                  (t) =>
                      DropdownMenuItem(value: t.profileId, child: Text(t.name)),
                )
                .toList(),
            onChanged: busy
                ? null
                : (id) => setState(
                    () => selected = targets
                        .where((t) => t.profileId == id)
                        .firstOrNull,
                  ),
          ),
          if (selected != null)
            Text(printerConnectionLabel(context, selected!.connection)),
          SwitchListTile(
            value: direct,
            title: Text(
              _t(
                context,
                'إرسال مباشر للطابعة المحددة إن دعمه النظام',
                'Direct submission to selected printer when supported',
              ),
            ),
            onChanged:
                busy ||
                    capabilities?.directPrint != true ||
                    capabilities?.canListPrinters != true
                ? null
                : (v) => setState(() => direct = v),
          ),
          FilledButton(
            onPressed: busy || selected == null ? null : save,
            child: Text(
              _t(context, 'حفظ اختيار هذا الجهاز', 'Save device choice'),
            ),
          ),
          OutlinedButton.icon(
            onPressed:
                busy || selected == null || capabilities?.canPrint != true
                ? null
                : test,
            icon: const Icon(Icons.print_outlined),
            label: Text(_t(context, 'اختبار الطباعة', 'Test printing')),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          _t(
            context,
            'USB وBluetooth وWi-Fi وLAN تعمل فقط إذا وفر النظام أو تعريف الشركة وسيلة متوافقة. المتصفح قد يحتاج وسيط الطباعة المحلي الموجود؛ لا يوجد دعم raw عام أو قطع ورق مضمون. لا يُعتمد أي موديل أو اتصال قبل اختبار الطابعة الحقيقية.',
            'USB, Bluetooth, Wi-Fi and LAN require a compatible OS service or vendor driver. Browsers may need the existing local bridge; generic raw access and paper cutting are not guaranteed. No model or connection is verified before physical testing.',
          ),
        ),
        OutlinedButton(
          onPressed: busy ? null : load,
          child: Text(
            _t(
              context,
              'تحديث الطابعات والصلاحيات',
              'Refresh printers and permissions',
            ),
          ),
        ),
      ],
    ),
  );
}
