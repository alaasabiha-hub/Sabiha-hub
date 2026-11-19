import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'offline_customer_claim.dart'
    show OfflineClaimGateway, SupabaseOfflineClaimGateway;
import 'workflow.dart' show newOrderRequestId;
import 'owner_recovery_proposal.dart';

/// Case-bound audited investigation. A candidate never constitutes identity proof.
class VisitRecoveryInvestigationController extends ChangeNotifier {
  VisitRecoveryInvestigationController({
    required this.gateway,
    required this.actorId,
    required this.caseId,
  }) : actor = actorId();
  final OfflineClaimGateway gateway;
  final String? Function() actorId;
  final String? actor;
  String caseId, purpose = '', plate = '';
  String? queryId, error, selected;
  Map<String, dynamic>? result, detail;
  bool busy = false, invalid = false, disposed = false;
  int epoch = 0;
  final Map<String, String> detailRequests = {};
  bool get current =>
      !disposed && !invalid && actor != null && actorId() == actor;
  bool get validInput =>
      purpose.trim().length >= 10 &&
      purpose.trim().length <= 300 &&
      plate.length <= 40 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(plate);
  List<Map<String, dynamic>> get candidates =>
      ((result?['candidates'] as List?) ?? [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  void changed() {
    if (!disposed) notifyListeners();
  }

  void clearQuery() {
    epoch++;
    queryId = null;
    selected = null;
    result = detail = null;
    detailRequests.clear();
    busy = false;
    error = null;
  }

  void configure(String nextPurpose, String nextPlate) {
    if (purpose == nextPurpose && plate == nextPlate) return;
    clearQuery();
    purpose = nextPurpose;
    plate = nextPlate;
    changed();
  }

  void changeCase(String next) {
    if (caseId == next) return;
    clearQuery();
    caseId = next;
    purpose = plate = '';
    changed();
  }

  void invalidate() {
    clearQuery();
    purpose = plate = '';
    invalid = true;
    error = 'identity';
    changed();
  }

  bool owns(int e) => current && e == epoch;
  void validateFlags(Map<String, dynamic> value) {
    if (value['case_id'] != caseId ||
        value['candidate_is_identity_proof'] != false ||
        value['proposal_enabled'] != false ||
        value['linking_enabled'] != false) {
      throw StateError('Unverified investigation');
    }
  }

  bool validCandidate(Map<dynamic, dynamic> row, int bound) {
    return row['profile_reference'] is String &&
        (row['profile_reference'] as String).isNotEmpty &&
        row['candidate_is_identity_proof'] == false &&
        row['independent_proof_required'] == true &&
        row['proposal_enabled'] == false &&
        row['linking_enabled'] == false &&
        [
          'real_receipt_available',
          'receipt_ever_linked',
          'active_profile_link',
          'active_requester_link',
          'contacts_truncated',
          'cars_truncated',
        ].every((key) => row[key] is bool) &&
        row['contacts'] is List &&
        (row['contacts'] as List).length <= bound &&
        row['cars'] is List &&
        (row['cars'] as List).length <= bound;
  }

  Future<void> search() async {
    if (!current || busy || !validInput) return;
    final e = ++epoch;
    queryId ??= newOrderRequestId();
    final id = queryId!;
    result = detail = null;
    selected = null;
    busy = true;
    error = null;
    changed();
    try {
      final value = Map<String, dynamic>.from(
        await gateway.rpc('search_visit_recovery_candidates', {
          'p_query': id,
          'p_case': caseId,
          'p_purpose': purpose.trim(),
          'p_plate': plate.trim().isEmpty ? null : plate.trim(),
          'p_limit': 10,
        }) as Map,
      );
      if (!owns(e)) return;
      validateFlags(value);
      final rows = value['candidates'];
      if (value['query_id'] != id ||
          rows is! List ||
          rows.length > 10 ||
          value['candidate_count'] != rows.length ||
          value['limit'] != 10 ||
          value['has_more'] is! bool ||
          ![
            'registered_phone',
            'exact_plate',
          ].contains(value['criterion_kind'])) {
        throw StateError('Unverified bounded result');
      }
      final ids = <String>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        if (!validCandidate(row, 5) ||
            !ids.add(row['profile_reference'] as String)) {
          throw StateError('Unverified candidate');
        }
      }
      result = value;
    } catch (_) {
      if (owns(e)) {
        result = detail = null;
        error = 'unavailable';
      }
    } finally {
      if (owns(e)) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> select(String profile) async {
    if (!current ||
        queryId == null ||
        !candidates.any((row) => row['profile_reference'] == profile)) {
      return;
    }
    final e = ++epoch, query = queryId!;
    final request = detailRequests.putIfAbsent(profile, newOrderRequestId);
    selected = profile;
    detail = null;
    busy = true;
    error = null;
    changed();
    try {
      final value = Map<String, dynamic>.from(
        await gateway.rpc('get_visit_recovery_candidate', {
          'p_request': request,
          'p_query': query,
          'p_profile': profile,
          'p_purpose': purpose.trim(),
          'p_plate': plate.trim().isEmpty ? null : plate.trim(),
        }) as Map,
      );
      if (!owns(e)) return;
      validateFlags(value);
      final row = value['candidate'];
      if (value['query_id'] != query ||
          value['request_id'] != request ||
          row is! Map ||
          row['profile_reference'] != profile ||
          !validCandidate(row, 25)) {
        throw StateError('Unverified candidate detail');
      }
      detail = Map<String, dynamic>.from(row);
    } catch (_) {
      if (owns(e)) {
        detail = null;
        error = 'unavailable';
      }
    } finally {
      if (owns(e)) {
        busy = false;
        changed();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    result = detail = null;
    detailRequests.clear();
    super.dispose();
  }
}

class VisitRecoveryInvestigationScreen extends StatefulWidget {
  const VisitRecoveryInvestigationScreen({
    super.key,
    required this.client,
    required this.caseId,
    this.gateway,
  });
  final SupabaseClient client;
  final String caseId;
  final OfflineClaimGateway? gateway;
  @override
  State<VisitRecoveryInvestigationScreen> createState() =>
      _VisitRecoveryInvestigationScreenState();
}

class _VisitRecoveryInvestigationScreenState
    extends State<VisitRecoveryInvestigationScreen> {
  late final VisitRecoveryInvestigationController flow;
  final purpose = TextEditingController(), plate = TextEditingController();
  StreamSubscription<AuthState>? auth;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    flow = VisitRecoveryInvestigationController(
      gateway: widget.gateway ?? SupabaseOfflineClaimGateway(widget.client),
      actorId: () => widget.client.auth.currentUser?.id,
      caseId: widget.caseId,
    );
    purpose.addListener(queryChanged);
    plate.addListener(queryChanged);
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final replay = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (replay || event.event == AuthChangeEvent.initialSession) return;
      flow.invalidate();
      purpose.clear();
      plate.clear();
    });
  }

  void queryChanged() => flow.configure(purpose.text, plate.text);
  @override
  void didUpdateWidget(covariant VisitRecoveryInvestigationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.gateway != widget.gateway) {
      flow.invalidate();
      purpose.clear();
      plate.clear();
    } else if (oldWidget.caseId != widget.caseId) {
      flow.changeCase(widget.caseId);
      purpose.clear();
      plate.clear();
    }
  }

  @override
  void dispose() {
    auth?.cancel();
    purpose.dispose();
    plate.dispose();
    flow.dispose();
    super.dispose();
  }

  String date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null
        ? t('غير متاح', 'Unavailable')
        : MaterialLocalizations.of(context).formatFullDate(parsed.toLocal());
  }

  Widget projection(Map<String, dynamic> row, {bool detailed = false}) {
    final branch = row['branch'] as Map?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${row['name'] ?? t('اسم غير متاح', 'Name unavailable')}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Text(
          '${t('فرع الاستقبال', 'Reception branch')}: ${branch?[Localizations.localeOf(context).languageCode == 'ar' ? 'name_ar' : 'name_en'] ?? t('غير متاح', 'Unavailable')}',
        ),
        if (detailed) ...[
          Text(
            '${t('تاريخ التسجيل', 'Registered on')}: ${date(row['created_at'])}',
          ),
          for (final contact in (row['contacts'] as List? ?? []))
            Text(
              '${contact['phone']} · ${contact['verification'] == 'observed_unverified' ? t('مسجل عند الاستقبال؛ الملكية غير مثبتة', 'Recorded at reception; ownership unverified') : t('حالة التحقق غير متاحة', 'Verification status unavailable')}',
            ),
          if (row['contacts_truncated'] == true)
            Text(t('قائمة الأرقام مختصرة.', 'Contact list is truncated.')),
          for (final car in (row['cars'] as List? ?? []))
            Text(
              '${t('السيارة', 'Vehicle')}: ${car['plate_number'] ?? ''} · ${[car['brand'], car['model'], car['year'], car['color']].where((v) => v != null).join(' · ')}',
            ),
          if (row['cars_truncated'] == true)
            Text(t('قائمة السيارات مختصرة.', 'Vehicle list is truncated.')),
          Text(
            row['real_receipt_available'] == true
                ? t(
                    'يوجد إيصال تسجيل فعلي.',
                    'An actual enrollment receipt exists.',
                  )
                : t(
                    'لم يُعثر على إيصال تسجيل فعلي.',
                    'No actual enrollment receipt was found.',
                  ),
          ),
          Text(
            row['receipt_ever_linked'] == true
                ? t(
                    'سبق ربط إيصال لهذا السجل.',
                    'A receipt for this record was previously linked.',
                  )
                : t(
                    'لا يوجد ربط سابق مسجل للإيصال.',
                    'No previous receipt link is recorded.',
                  ),
          ),
          if (row['active_profile_link'] == true)
            Text(
              t('يوجد ربط نشط لهذا السجل.', 'This record has an active link.'),
            ),
          if (row['active_requester_link'] == true)
            Text(
              t(
                'يوجد ربط نشط لطالب الاسترجاع.',
                'The requester has an active link.',
              ),
            ),
        ],
      ],
    );
  }

  Widget identified(String id, Widget child) =>
      Semantics(identifier: id, child: child);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(
        t('التحقق من سجلات الاستقبال', 'Investigate reception records'),
      ),
    ),
    body: AnimatedBuilder(
      animation: flow,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            t(
              'للمالك وفي نطاق هذا الطلب فقط. تطابق الهاتف أو اللوحة لا يثبت الهوية ولا يربط أي سجل.',
              'Owner investigation for this case only. A phone or plate match does not prove identity or link any record.',
            ),
          ),
          const SizedBox(height: 12),
          identified(
            'visit-investigation-purpose',
            TextField(
              key: const ValueKey('investigation-purpose'),
              controller: purpose,
              enabled: flow.current,
              maxLength: 300,
              minLines: 2,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: t(
                  'الغرض من التحقق (١٠ أحرف على الأقل)',
                  'Investigation purpose (at least 10 characters)',
                ),
              ),
            ),
          ),
          identified(
            'visit-investigation-plate',
            TextField(
              key: const ValueKey('investigation-plate'),
              controller: plate,
              enabled: flow.current,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: t(
                  'لوحة السيارة الدقيقة (اختياري)',
                  'Exact vehicle plate (optional)',
                ),
              ),
            ),
          ),
          Text(
            t(
              'دون لوحة، يُستخدم الهاتف الحالي المسجل في الطلب. البحث دقيق ويعرض حتى ١٠ سجلات.',
              'Without a plate, the case’s current registered phone is used. Exact matching returns at most 10 records.',
            ),
          ),
          const SizedBox(height: 12),
          identified(
            'visit-investigation-search',
            FilledButton(
              key: const ValueKey('investigation-search'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xff174b83),
              ),
              onPressed: flow.current && flow.validInput && !flow.busy
                  ? flow.search
                  : null,
              child: Text(
                t('التحقق من السجلات المحتملة', 'Investigate possible records'),
              ),
            ),
          ),
          if (flow.busy) const LinearProgressIndicator(),
          if (flow.error != null || flow.invalid)
            Text(
              flow.invalid
                  ? t(
                      'تغيرت الجلسة. أعد فتح الطلب بالحساب المصرح له.',
                      'Session changed. Reopen the case with an authorized account.',
                    )
                  : t(
                      'تعذر تأكيد النتائج. تحقق من صلاحيتك وحالة الطلب ثم أعد المحاولة بنفس البيانات.',
                      'Results could not be confirmed. Check your access and case status, then retry the same criteria.',
                    ),
            ),
          if (flow.result != null) ...[
            Text(
              '${t('آخر تحقق من الخادم', 'Server checked on')}: ${date(flow.result!['checked_at'])}',
            ),
            if (flow.candidates.isEmpty)
              Text(
                t(
                  'لا توجد سجلات مطابقة لهذا المعيار.',
                  'No records match this exact criterion.',
                ),
              ),
            if (flow.result!['has_more'] == true)
              Text(
                t(
                  'توجد نتائج إضافية؛ ضيّق البحث بلوحة دقيقة. لا نفترض اختياراً تلقائياً.',
                  'More results exist; refine with an exact plate. No candidate is selected automatically.',
                ),
              ),
            for (final row in flow.candidates)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      projection(row),
                      identified(
                        'visit-investigation-select-${row['profile_reference']}',
                        TextButton(
                          key: ValueKey(
                            'investigation-select-${row['profile_reference']}',
                          ),
                          onPressed: flow.current
                              ? () => flow.select(
                                  row['profile_reference'] as String,
                                )
                              : null,
                          child: Text(
                            t(
                              'عرض تفاصيل هذا السجل للمراجعة',
                              'Review details of this record',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (flow.detail != null)
            identified(
              'visit-investigation-detail',
              Card(
                key: const ValueKey('investigation-detail'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      projection(flow.detail!, detailed: true),
                      const SizedBox(height: 12),
                      Text(
                        t(
                          'اقتراح مستقل يتطلب دليلاً فعلياً وموافقة العميل؛ ليس اعتماداً لنتيجة البحث.',
                          'A separate proposal requires actual independent evidence and customer consent; it does not approve this search result.',
                        ),
                      ),
                      if (flow.detail!['real_receipt_available'] == true &&
                          flow.detail!['receipt_ever_linked'] == false &&
                          flow.detail!['active_profile_link'] == false &&
                          flow.detail!['active_requester_link'] == false)
                        identified(
                          'owner-proposal-open',
                          TextButton(
                            key: const ValueKey('owner-proposal-open'),
                            onPressed: flow.current && !flow.busy
                                ? () async {
                                    final query = flow.queryId!,
                                        profile =
                                            flow.detail!['profile_reference']
                                                as String;
                                    await Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            OwnerRecoveryProposalScreen(
                                              client: widget.client,
                                              caseId: flow.caseId,
                                              query: query,
                                              profile: profile,
                                              plate: flow.plate.trim().isEmpty
                                                  ? null
                                                  : flow.plate.trim(),
                                              gateway: widget.gateway,
                                            ),
                                      ),
                                    );
                                    if (mounted &&
                                        flow.current &&
                                        flow.queryId == query &&
                                        flow.selected == profile) {
                                      await flow.select(profile);
                                    }
                                  }
                                : null,
                            child: Text(
                              t(
                                'اقتراح هذا السجل للتحقق المستقل',
                                'Propose this record for independent verification',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          identified(
            'visit-investigation-no-link-note',
            Text(
              key: const ValueKey('investigation-no-link-note'),
              t(
                'هذه نتائج للتحقق وليست دليلاً مستقلاً. اقتراح الربط أو اعتماده غير متاح هنا.',
                'These are investigation candidates, not independent proof. Proposing or approving a link is unavailable here.',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
