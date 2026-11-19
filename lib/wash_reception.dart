import 'dart:async';

import 'package:flutter/material.dart';

import 'emergency_reception.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'customer_booking_ui.dart' show bookingReference;
import 'branch_settings.dart' show BranchSelection;
import 'customer_visuals.dart' show customerText;
import 'workflow.dart' show newOrderRequestId;
import 'invoices.dart';

bool canManageReception(String? role) => role == 'owner' || role == 'manager';
String receptionState(Map row, bool arabic) => row['branch_conflict'] == true
    ? (arabic ? 'فرع الاستقبال يحتاج مراجعة' : 'Reception branch needs review')
    : row['status'] == 'in_progress'
    ? (arabic ? 'قيد الخدمة' : 'In service')
    : (row['arrived'] == true || row['arrived_at'] != null)
    ? (row['vip'] == true
          ? 'VIP'
          : (arabic ? 'حاضر · عادي' : 'Arrived · standard'))
    : (arabic ? 'لم يصل بعد' : 'Not arrived');

/// Reception records arrival and priority; existing service/inspection actions
/// remain responsible for starting and completing the visit.
class WashReceptionScreen extends StatefulWidget {
  final SupabaseClient client;
  final String role;
  final void Function(Map<String, dynamic>)? onVisit;
  const WashReceptionScreen({
    super.key,
    required this.client,
    required this.role,
    this.onVisit,
  });
  @override
  State<WashReceptionScreen> createState() => _WashReceptionScreenState();
}

/// A branch-authorized summary for an already received walk-in. It deliberately
/// does not offer booking-only arrival transitions for this visit type.
class WalkInReceptionDetailsScreen extends StatelessWidget {
  const WalkInReceptionDetailsScreen({
    super.key,
    required this.client,
    required this.role,
    required this.visit,
  });
  final SupabaseClient client;
  final String role;
  final Map<String, dynamic> visit;

  @override
  Widget build(BuildContext context) {
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    String t(String ar, String en) => arabic ? ar : en;
    final classCode = visit['vehicle_class_code']?.toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(t('تفاصيل الاستلام المباشر', 'Walk-in reception details')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${visit['work_reference'] ?? ''}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text('${t('العميل', 'Customer')}: ${visit['customer_name'] ?? ''}'),
          Text(
            '${t('السيارة', 'Vehicle')}: ${visit['brand'] ?? ''} ${visit['model'] ?? ''}',
          ),
          Text('${t('اللوحة', 'Plate')}: ${visit['plate_number'] ?? ''}'),
          Text('${t('الفئة', 'Class')}: ${classCode ?? '—'}'),
          if (visit['odometer_km'] != null)
            Text(
              '${t('قراءة العداد', 'Odometer')}: ${visit['odometer_km']} km',
            ),
          Text('${t('الخدمة', 'Service')}: ${visit['service_name'] ?? ''}'),
          Text('${t('الحالة', 'Status')}: ${receptionState(visit, arabic)}'),
          Text(
            '${t('الأولوية', 'Priority')}: ${visit['priority'] == 'vip' ? 'VIP' : t('عادي', 'Normal')}',
          ),
          Text('${t('المبلغ', 'Amount')}: ${visit['amount_due'] ?? '—'} EGP'),
          const SizedBox(height: 16),
          if (visit['invoice_token'] is String &&
              (visit['invoice_token'] as String).isNotEmpty)
            FilledButton.icon(
              icon: const Icon(Icons.receipt_long),
              label: Text(t('فتح الفاتورة', 'Open invoice')),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => InvoiceDocumentsScreen(
                    client: client,
                    role: role,
                    initialToken: visit['invoice_token'] as String,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WashReceptionScreenState extends State<WashReceptionScreen> {
  List<Map<String, dynamic>> rows = [];
  bool loading = true, busy = false;
  String? error;
  Map<String, dynamic>? pending;
  late final Session? receptionSession;
  StreamSubscription<AuthState>? receptionAuth;
  bool identityChanged = false;
  bool get viewCurrent =>
      mounted &&
      (receptionSession == null ||
          !identityChanged &&
              widget.client.auth.currentUser?.id == receptionSession?.user.id &&
              widget.client.auth.currentSession?.accessToken ==
                  receptionSession?.accessToken);
  bool get canUseEmergency =>
      viewCurrent &&
      receptionSession != null &&
      canManageReception(widget.role);
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => customerText(context, a, e);
  @override
  void initState() {
    super.initState();
    receptionSession = widget.client.accessToken == null
        ? widget.client.auth.currentSession
        : null;
    if (receptionSession != null) {
      receptionAuth = widget.client.auth.onAuthStateChange.listen((event) {
        final replay =
            event.session?.accessToken == receptionSession?.accessToken &&
            event.session?.user.id == receptionSession?.user.id &&
            const {
              AuthChangeEvent.initialSession,
              AuthChangeEvent.signedIn,
              AuthChangeEvent.tokenRefreshed,
            }.contains(event.event);
        if (replay || !mounted || identityChanged) return;
        setState(() {
          identityChanged = true;
          rows = [];
          pending = null;
          busy = false;
          loading = false;
        });
      });
    }
    load();
  }

  Future<void> load() async {
    if (!viewCurrent) return;
    if (viewCurrent) {
      setState(() => loading = true);
    }
    try {
      final result = await widget.client.rpc(
        'get_wash_reception_queue',
        params: {'p_branch': BranchSelection.current},
      );
      final walkIns = await widget.client.rpc(
        'list_offline_walk_in_reception',
        params: {'p_branch': BranchSelection.current},
      );
      if (viewCurrent) {
        final merged = <Map<String, dynamic>>[
          ...List<Map<String, dynamic>>.from(result as List),
          ...List<Map<String, dynamic>>.from(walkIns as List).map(
            (row) => {
              ...row,
              'arrived': true,
              'vip': row['priority'] == 'vip',
              'booking_time': row['arrived_at'] ?? '',
            },
          ),
        ];
        merged.sort((a, b) {
          final aInService = a['status'] == 'in_progress' ? 0 : 1;
          final bInService = b['status'] == 'in_progress' ? 0 : 1;
          if (aInService != bInService) return aInService.compareTo(bInService);
          final aVip = a['vip'] == true ? 0 : 1;
          final bVip = b['vip'] == true ? 0 : 1;
          if (aVip != bVip) return aVip.compareTo(bVip);
          final aTime =
              DateTime.tryParse(
                '${a['arrived_at'] ?? a['booking_date'] ?? ''}',
              ) ??
              DateTime(2100);
          final bTime =
              DateTime.tryParse(
                '${b['arrived_at'] ?? b['booking_date'] ?? ''}',
              ) ??
              DateTime(2100);
          return aTime.compareTo(bTime);
        });
        setState(() {
          rows = merged;
          error = null;
        });
      }
    } catch (_) {
      if (viewCurrent) {
        setState(
          () => error = t(
            'تعذر تحميل طابور الاستقبال.',
            'Unable to load reception queue.',
          ),
        );
      }
    } finally {
      if (viewCurrent) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> submit(Map<String, dynamic> payload) async {
    if (!viewCurrent) return;
    setState(() {
      busy = true;
      pending = payload;
      error = null;
    });
    try {
      await widget.client.rpc('update_wash_reception', params: payload);
      pending = null;
      await load();
    } catch (failure) {
      if (failure is PostgrestException &&
          const {'22023', '42501', '40001', '55000'}.contains(failure.code)) {
        pending = null;
        if (viewCurrent) {
          setState(() => error = failure.message);
        }
      } else if (viewCurrent) {
        setState(
          () => error = t(
            'النتيجة غير مؤكدة. أعد نفس الطلب قبل تغيير أي أولوية أخرى.',
            'Result unconfirmed. Retry the same request before changing another priority.',
          ),
        );
      }
    } finally {
      if (viewCurrent) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> change(Map<String, dynamic> row) async {
    String priority = row['priority'] as String? ?? 'normal';
    String reason = '';
    if (!viewCurrent) return;
    final accepted = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => AlertDialog(
          title: Text(
            row['arrived'] == true
                ? t('تغيير أولوية الاستقبال', 'Change reception priority')
                : t('تسجيل الوصول', 'Register arrival'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: priority,
                items: [
                  DropdownMenuItem(
                    value: 'normal',
                    child: Text(t('عادي', 'Standard')),
                  ),
                  const DropdownMenuItem(value: 'vip', child: Text('VIP')),
                ],
                onChanged: (value) => refresh(() => priority = value!),
              ),
              TextField(
                onChanged: (value) => reason = value,
                maxLength: 300,
                decoration: InputDecoration(
                  labelText: t(
                    'سبب موثق (٥ أحرف على الأقل)',
                    'Recorded reason (at least 5 characters)',
                  ),
                ),
              ),
              Text(
                t(
                  'الأولوية لا تتجاوز تأكيد الحجز أو الفحص أو الدفع.',
                  'Priority does not bypass booking confirmation, inspection or payment.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(t('رجوع', 'Back')),
            ),
            if (canUseEmergency)
              TextButton(
                onPressed: () => Navigator.pop(dialog, 'local'),
                child: Text(
                  t('حفظ مسودة محلية للطوارئ', 'Save local emergency draft'),
                ),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, 'online'),
              child: Text(t('حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );
    final savedReason = reason.trim();
    if (accepted == null || !viewCurrent) {
      return;
    }
    if (savedReason.length < 5) {
      setState(
        () => error = t(
          'أدخل سببًا موثقًا من ٥ أحرف على الأقل.',
          'Enter a recorded reason of at least 5 characters.',
        ),
      );
      return;
    }
    final payload = <String, dynamic>{
      'p_request': newOrderRequestId(),
      'p_booking': row['id'],
      'p_action': row['arrived'] == true ? 'priority' : 'arrive',
      'p_priority': priority,
      'p_expected_revision': row['revision'] ?? 0,
      'p_reason': savedReason,
    };
    if (accepted == 'local') {
      if (!canUseEmergency) return;
      await openEmergency(
        candidate: {
          'request': payload,
          'branch_id': row['branch_id'],
          'reference': row['booking_number'],
          'device_time': DateTime.now().toUtc().toIso8601String(),
        },
      );
    } else {
      await submit(payload);
    }
  }

  Future<void> openEmergency({Map<String, dynamic>? candidate}) async {
    if (!canUseEmergency || busy || pending != null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmergencyReceptionScreen(
          gateway: SupabaseEmergencyReceptionGateway(widget.client),
          candidate: candidate,
        ),
      ),
    );
    if (viewCurrent) await load();
  }

  @override
  void dispose() {
    receptionAuth?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: pending == null,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          t('استقبال السيارات وأولوية VIP', 'Vehicle reception & VIP priority'),
        ),
        actions: [
          if (canUseEmergency)
            IconButton(
              tooltip: t('سجل الطوارئ المشفر', 'Encrypted emergency journal'),
              onPressed: busy || pending != null ? null : () => openEmergency(),
              icon: const Icon(Icons.cloud_off_outlined),
            ),
          IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  t(
                    'زيارات اليوم بتوقيت القاهرة. الجاري خدمتها أولًا؛ الحاضرون VIP ثم وقت الوصول. الأولوية لا تبدأ الخدمة تلقائيًا.',
                    'Today in Cairo. In-service visits first; arrived VIP then arrival order. Priority never starts service automatically.',
                  ),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
                if (pending != null)
                  FilledButton(
                    onPressed: busy ? null : () => submit(pending!),
                    child: Text(t('إعادة نفس الطلب', 'Retry same request')),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      t(
                        'لا توجد زيارات مؤكدة ظاهرة اليوم.',
                        'No confirmed visits visible today.',
                      ),
                    ),
                  ),
                ...rows.map(
                  (row) => Card(
                    child: ListTile(
                      leading: Icon(
                        row['vip'] == true ? Icons.star : Icons.directions_car,
                      ),
                      title: Text(
                        '${row['source_kind'] == 'walk_in' ? row['work_reference'] : bookingReference(row)} · ${row['service_name']}',
                      ),
                      subtitle: Text(
                        '${row['plate_number'] ?? ''} · ${row['booking_time'] ?? ''}${row['source_kind'] == 'walk_in' ? '' : '\n${ar ? row['branch_name_ar'] : row['branch_name_en']}'} · ${receptionState(row, ar)}',
                      ),
                      isThreeLine: true,
                      onTap: widget.onVisit == null
                          ? null
                          : () => widget.onVisit!(row),
                      trailing:
                          row['source_kind'] != 'walk_in' &&
                              canManageReception(widget.role) &&
                              row['status'] == 'confirmed' &&
                              row['branch_conflict'] != true
                          ? TextButton(
                              onPressed: busy || pending != null
                                  ? null
                                  : () => change(row),
                              child: Text(
                                row['arrived'] == true
                                    ? t('الأولوية', 'Priority')
                                    : t('وصل', 'Arrived'),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                if (busy) const LinearProgressIndicator(),
              ],
            ),
    ),
  );
}
