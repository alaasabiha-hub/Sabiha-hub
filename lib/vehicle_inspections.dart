import 'customer_visuals.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'customer_care.dart' show uploadCareImage;
import 'workflow.dart' show newOrderRequestId;
import 'inspection_pdf.dart';
import 'wash_reception.dart'
    show WashReceptionScreen, WalkInReceptionDetailsScreen;
import 'cashier_shifts.dart';

const inspectionViews = {
  'front': 'الأمام',
  'back': 'الخلف',
  'left': 'الجانب الأيسر',
  'right': 'الجانب الأيمن',
  'interior': 'الداخل',
  'damage': 'ضرر إضافي',
  'signature': 'توقيع العميل',
};

class InspectionHubScreen extends StatefulWidget {
  final SupabaseClient client;
  final String? role;
  final String? bookingId;
  const InspectionHubScreen({
    super.key,
    required this.client,
    this.role,
    this.bookingId,
  });
  @override
  State<InspectionHubScreen> createState() => _InspectionHubScreenState();
}

class _InspectionHubScreenState extends State<InspectionHubScreen> {
  List<Map<String, dynamic>> bookings = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      var query = widget.client
          .from('bookings')
          .select('id,service_name,booking_date,booking_time,status,branch_id');
      if (widget.bookingId != null) {
        query = query.eq('id', widget.bookingId!);
      } else if (widget.role == null) {
        query = query.eq('customer_id', widget.client.auth.currentUser!.id);
      }
      bookings = List<Map<String, dynamic>>.from(
        await query.order('booking_date', ascending: false).limit(100),
      );
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'تعذر تحميل زيارات السيارة.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => CustomerAdaptiveFrame(
    enabled: widget.role == null,
    title: customerText(
      context,
      'فحص سيارتي وصورها',
      'Vehicle inspection & photos',
    ),
    selected: 2,
    appBar: AppBar(
      title: Text(
        widget.role == null
            ? customerText(context, 'فحص سيارتي', 'My vehicle inspection')
            : customerText(
                context,
                'فحص استلام وتسليم السيارات',
                'Vehicle intake & delivery inspections',
              ),
      ),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.role != null) ...[
                FilledButton.icon(
                  key: const ValueKey('receive_new_vehicle'),
                  icon: const Icon(Icons.add_circle_outline),
                  label: Text(
                    customerText(
                      context,
                      'استلام سيارة جديدة',
                      'Receive a new car',
                    ),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CashierShiftsScreen(
                        client: widget.client,
                        role: widget.role!,
                        initialWalkInPriority: 'normal',
                      ),
                    ),
                  ),
                ),
                FilledButton.icon(
                  key: const ValueKey('receive_vip_vehicle'),
                  icon: const Icon(Icons.star_border),
                  label: Text(
                    customerText(
                      context,
                      'استلام سيارة VIP',
                      'Receive a VIP car',
                    ),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CashierShiftsScreen(
                        client: widget.client,
                        role: widget.role!,
                        initialWalkInPriority: 'vip',
                      ),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.low_priority),
                  label: Text(
                    customerText(
                      context,
                      'طابور الاستقبال وأولوية VIP',
                      'Reception queue & VIP priority',
                    ),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WashReceptionScreen(
                        client: widget.client,
                        role: widget.role!,
                        onVisit: (visit) => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => visit['source_kind'] == 'walk_in'
                                ? WalkInReceptionDetailsScreen(
                                    client: widget.client,
                                    role: widget.role!,
                                    visit: visit,
                                  )
                                : InspectionVisitScreen(
                                    client: widget.client,
                                    booking: visit,
                                    role: widget.role,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (error != null)
                Text(
                  customerText(
                    context,
                    'تعذر تحميل زيارات السيارة.',
                    'Unable to load vehicle visits.',
                  ),
                ),
              if (bookings.isEmpty && error == null)
                Text(
                  customerText(
                    context,
                    'لا توجد زيارات ظاهرة لحسابك.',
                    'No visits are visible for your account.',
                  ),
                ),
              ...bookings.map(
                (b) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.car_crash_outlined),
                    title: Text('${b['service_name']} · ${b['booking_date']}'),
                    subtitle: Text('${b['booking_time']} · ${b['status']}'),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => InspectionVisitScreen(
                          client: widget.client,
                          booking: b,
                          role: widget.role,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}

class InspectionVisitScreen extends StatefulWidget {
  final SupabaseClient client;
  final Map<String, dynamic> booking;
  final String? role;
  const InspectionVisitScreen({
    super.key,
    required this.client,
    required this.booking,
    this.role,
  });
  @override
  State<InspectionVisitScreen> createState() => _InspectionVisitScreenState();
}

class _InspectionVisitScreenState extends State<InspectionVisitScreen> {
  List<Map<String, dynamic>> inspections = [], media = [];
  Map<String, dynamic>? visit;
  bool loading = true, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final id = widget.booking['id'];
      inspections = List<Map<String, dynamic>>.from(
        await widget.client
            .from('vehicle_inspections')
            .select()
            .eq('booking_id', id)
            .order('revision', ascending: false),
      );
      visit = Map<String, dynamic>.from(
        await widget.client.rpc(
          'inspection_context',
          params: {'p_booking': id},
        ),
      );
      final ids = inspections.map((i) => i['inspection_id'] as String).toList();
      media = ids.isEmpty
          ? []
          : List<Map<String, dynamic>>.from(
              await widget.client
                  .from('vehicle_inspection_media')
                  .select()
                  .inFilter('inspection_id', ids),
            );
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'تعذر تحميل الفحص والصور الخاصة.';
        });
      }
    }
  }

  Future<void> begin(String phase, {String? previous, String? reason}) async {
    setState(() => busy = true);
    try {
      final id = await widget.client.rpc(
        'begin_vehicle_inspection',
        params: {
          'p_booking': widget.booking['id'],
          'p_phase': phase,
          'p_previous': previous,
          'p_reason': reason,
        },
      );
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                InspectionEditorScreen(client: widget.client, inspectionId: id),
          ),
        );
      }
      await load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر فتح الفحص. يلزم موظف مخول وسيارة مسجلة وحالة خدمة مناسبة.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pdf(Map<String, dynamic> inspection) async {
    setState(() => busy = true);
    try {
      final pictures = <Map<String, dynamic>>[];
      for (final m in media.where(
        (m) => m['inspection_id'] == inspection['inspection_id'],
      )) {
        pictures.add({
          ...m,
          'bytes': await widget.client.storage
              .from('vehicle-inspections')
              .download(m['storage_path']),
        });
      }
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf'),
          logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildInspectionPdf(
        inspection,
        visit!,
        pictures,
        font.buffer.asUint8List(),
        logo.buffer.asUint8List(),
      );
      await FilePicker.saveFile(
        fileName: 'Sabiha-inspection-${inspection['inspection_id']}.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر إنشاء التقرير أو تحميل الصور المصرح بها.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget picture(Map<String, dynamic> m) {
    return FutureBuilder<String>(
      future: widget.client.storage
          .from('vehicle-inspections')
          .createSignedUrl(m['storage_path'], 300),
      builder: (c, s) {
        if (!s.hasData) {
          return const SizedBox(
            height: 70,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return GestureDetector(
          onTap: () => showDialog(
            context: context,
            builder: (d) => Dialog(
              child: InteractiveViewer(
                child: Image.network(
                  s.data!,
                  errorBuilder: (_, e, t) => const Text('تعذر عرض الصورة'),
                ),
              ),
            ),
          ),
          child: Image.network(
            s.data!,
            height: 180,
            fit: BoxFit.contain,
            errorBuilder: (_, e, t) => const Text('تعذر عرض الصورة'),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final approved = inspections
        .where((i) => i['status'] == 'approved')
        .toList();
    final before = approved.where((i) => i['phase'] == 'before').firstOrNull;
    final after = approved.where((i) => i['phase'] == 'after').firstOrNull;
    return CustomerAdaptiveFrame(
      enabled: widget.role == null,
      title: customerText(context, 'قبل وبعد الخدمة', 'Before & after care'),
      selected: 2,
      appBar: AppBar(
        title: const Text('فحص سيارتي · قبل وبعد'),
        actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (error != null) Text(error!),
                if (busy) const LinearProgressIndicator(),
                if (visit != null)
                  Text(
                    '${visit!['vehicle_brand'] ?? ''} ${visit!['vehicle_model'] ?? ''} · ${visit!['plate_number'] ?? ''}\n${widget.booking['booking_date']} · ${widget.booking['service_name']}',
                  ),
                if (widget.role != null)
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy ? null : () => begin('before'),
                        child: const Text('فحص الاستلام / قبل'),
                      ),
                      OutlinedButton(
                        onPressed: busy ? null : () => begin('after'),
                        child: const Text('فحص التسليم / بعد'),
                      ),
                    ],
                  ),
                if (before == null)
                  const Text('سيظهر فحص الاستلام بعد اعتماده.'),
                if (after == null)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'لا تتوفر صور ما بعد الخدمة بعد. ستظهر بعد اعتماد فحص التسليم.',
                    ),
                  ),
                const Text(
                  'مقارنة الصور المعتمدة',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                ...['front', 'back', 'left', 'right', 'interior'].map(
                  (view) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(inspectionViews[view]!),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                const Text('قبل'),
                                if (before != null)
                                  ...media
                                      .where(
                                        (m) =>
                                            m['inspection_id'] ==
                                                before['inspection_id'] &&
                                            m['kind'] == view,
                                      )
                                      .map(picture)
                                else
                                  const Text('قيد الاعتماد'),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              children: [
                                const Text('بعد'),
                                if (after != null)
                                  ...media
                                      .where(
                                        (m) =>
                                            m['inspection_id'] ==
                                                after['inspection_id'] &&
                                            m['kind'] == view,
                                      )
                                      .map(picture)
                                else
                                  const Text('غير متوفر بعد'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(),
                    ],
                  ),
                ),
                const Text(
                  'تقارير الزيارة وسجل المراجعات',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                ...inspections.map(
                  (i) => Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i['phase'] == 'before' ? 'فحص الاستلام' : 'فحص التسليم'} · مراجعة ${i['revision']} · ${i['status'] == 'approved' ? 'معتمد' : 'مسودة'}',
                          ),
                          Text('${i['vehicle_condition']}\n${i['notes']}'),
                          Text(
                            'التوثيق: ${i['recorded_at']}\nالاعتماد: ${i['approved_at'] ?? 'لم يعتمد'}\nالعداد: ${i['odometer'] ?? 'غير مسجل'}',
                          ),
                          ...((i['damage_markers'] as List?) ?? []).map(
                            (m) => Text(
                              '${inspectionViews[m['view']]} · ${m['type']} · ${m['note'] ?? ''}',
                            ),
                          ),
                          if (i['signature_unavailable_reason'] != null)
                            Text(
                              'توثيق التوقيع: ${i['signature_unavailable_reason']}',
                            ),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (i['status'] == 'approved')
                                TextButton(
                                  onPressed: busy ? null : () => pdf(i),
                                  child: const Text('تحميل تقرير الفحص PDF'),
                                ),
                              if (widget.role != null && i['status'] == 'draft')
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  InspectionEditorScreen(
                                                    client: widget.client,
                                                    inspectionId:
                                                        i['inspection_id'],
                                                  ),
                                            ),
                                          );
                                          await load();
                                        },
                                  child: const Text('استكمال المسودة'),
                                ),
                              if (widget.role == 'owner' &&
                                  i['status'] == 'approved')
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          final reason =
                                              TextEditingController();
                                          final ok = await showDialog<bool>(
                                            context: context,
                                            builder: (c) => AlertDialog(
                                              title: const Text(
                                                'تصحيح بفحص جديد مع حفظ الأصل',
                                              ),
                                              content: TextField(
                                                controller: reason,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'سبب المراجعة',
                                                    ),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(c, false),
                                                  child: const Text('إلغاء'),
                                                ),
                                                FilledButton(
                                                  onPressed: () =>
                                                      Navigator.pop(c, true),
                                                  child: const Text(
                                                    'إنشاء مراجعة',
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                          final text = reason.text;
                                          reason.dispose();
                                          if (ok == true) {
                                            await begin(
                                              i['phase'],
                                              previous: i['inspection_id'],
                                              reason: text,
                                            );
                                          }
                                        },
                                  child: const Text(
                                    'مراجعة موثقة دون تغيير الأصل',
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class InspectionEditorScreen extends StatefulWidget {
  final SupabaseClient client;
  final String inspectionId;
  const InspectionEditorScreen({
    super.key,
    required this.client,
    required this.inspectionId,
  });
  @override
  State<InspectionEditorScreen> createState() => _InspectionEditorScreenState();
}

class _InspectionEditorScreenState extends State<InspectionEditorScreen> {
  Map<String, dynamic>? inspection;
  List<Map<String, dynamic>> media = [], markers = [];
  final notes = TextEditingController(),
      condition = TextEditingController(),
      odometer = TextEditingController(),
      unsigned = TextEditingController(),
      damageNote = TextEditingController();
  String view = 'front', damageType = 'scratch';
  bool consent = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [notes, condition, odometer, unsigned, damageNote]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final i = await widget.client
          .from('vehicle_inspections')
          .select()
          .eq('inspection_id', widget.inspectionId)
          .single();
      final m = await widget.client
          .from('vehicle_inspection_media')
          .select()
          .eq('inspection_id', widget.inspectionId);
      if (mounted) {
        setState(() {
          inspection = i;
          media = List<Map<String, dynamic>>.from(m);
          markers = List<Map<String, dynamic>>.from(i['damage_markers']);
          notes.text = i['notes'];
          condition.text = i['vehicle_condition'];
          odometer.text = i['odometer']?.toString() ?? '';
          unsigned.text = i['signature_unavailable_reason'] ?? '';
          consent = i['signature_consent'];
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'تعذر تحميل مسودة الفحص.');
    }
  }

  Future<void> save() async {
    if (inspection == null) return;
    await widget.client.rpc(
      'save_vehicle_inspection',
      params: {
        'p_inspection': widget.inspectionId,
        'p_expected': inspection!['version'],
        'p_notes': notes.text,
        'p_condition': condition.text,
        'p_odometer': odometer.text.trim().isEmpty
            ? null
            : int.parse(odometer.text),
        'p_markers': markers,
        'p_consent': consent,
        'p_unsigned_reason': unsigned.text,
      },
    );
    await load();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'تعذر الحفظ. حدّث التقرير وتحقق من الصلاحية والحقول والصور المطلوبة.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> upload(String kind) async {
    await run(() async {
      await save();
      final path = await uploadCareImage(
        widget.client,
        'vehicle-inspections',
        '${widget.inspectionId}/$kind',
      );
      if (path != null) {
        await widget.client.rpc(
          'register_inspection_media',
          params: {
            'p_inspection': widget.inspectionId,
            'p_kind': kind,
            'p_path': path,
            'p_caption': null,
          },
        );
        await load();
      }
    });
  }

  Future<void> signature() async {
    await run(() async {
      await save();
      if (!mounted) return;
      final bytes = await showDialog<Uint8List>(
        context: context,
        builder: (_) => const SignatureCaptureDialog(),
      );
      if (bytes == null) return;
      final path =
          '${widget.inspectionId}/signature/${newOrderRequestId()}.png';
      await widget.client.storage
          .from('vehicle-inspections')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/png'),
          );
      await widget.client.rpc(
        'register_inspection_media',
        params: {
          'p_inspection': widget.inspectionId,
          'p_kind': 'signature',
          'p_path': path,
          'p_caption': 'Customer signature captured on staff device',
        },
      );
      await load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final i = inspection;
    final editable = i?['status'] == 'draft';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          i?['status'] == 'approved'
              ? 'فحص معتمد · الأصل محفوظ'
              : 'مسودة فحص السيارة',
        ),
        actions: [
          IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: i == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Text(error!),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
                if (busy) const LinearProgressIndicator(),
                TextField(
                  controller: condition,
                  enabled: editable,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    labelText: 'حالة السيارة عند الاستلام أو التسليم',
                  ),
                ),
                TextField(
                  controller: notes,
                  enabled: editable,
                  maxLines: 3,
                  maxLength: 3000,
                  decoration: const InputDecoration(
                    labelText: 'الملاحظات والخدوش والصدمات',
                  ),
                ),
                TextField(
                  controller: odometer,
                  enabled: editable,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'قراءة العداد (اختياري)',
                  ),
                ),
                const Text('مخطط مواضع الضرر · حدّد الجهة ثم المس مكان الضرر'),
                DropdownButtonFormField<String>(
                  initialValue: view,
                  items: ['front', 'back', 'left', 'right', 'interior']
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(inspectionViews[v]!),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => view = v!),
                ),
                if (editable) ...[
                  DropdownButtonFormField<String>(
                    initialValue: damageType,
                    items: const [
                      DropdownMenuItem(value: 'scratch', child: Text('خدش')),
                      DropdownMenuItem(value: 'dent', child: Text('صدمة')),
                      DropdownMenuItem(
                        value: 'other',
                        child: Text('ملاحظة أخرى'),
                      ),
                    ],
                    onChanged: (v) => setState(() => damageType = v!),
                  ),
                  TextField(
                    controller: damageNote,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      labelText: 'ملاحظة موضع الضرر',
                    ),
                  ),
                ],
                LayoutBuilder(
                  builder: (c, constraints) => GestureDetector(
                    onTapDown: !editable || busy
                        ? null
                        : (d) {
                            if (markers.length >= 50) return;
                            setState(
                              () => markers.add({
                                'view': view,
                                'type': damageType,
                                'x': (d.localPosition.dx / constraints.maxWidth)
                                    .clamp(0.0, 1.0),
                                'y': (d.localPosition.dy / 180).clamp(0.0, 1.0),
                                'note': damageNote.text,
                              }),
                            );
                          },
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, 180),
                      painter: VehicleDamagePainter(
                        markers.where((m) => m['view'] == view).toList(),
                      ),
                    ),
                  ),
                ),
                ...markers.asMap().entries.map(
                  (e) => ListTile(
                    title: Text(
                      '${inspectionViews[e.value['view']]} · ${e.value['type']}',
                    ),
                    subtitle: Text(e.value['note'] ?? ''),
                    trailing: editable
                        ? IconButton(
                            tooltip: 'إزالة العلامة من المسودة',
                            onPressed: () =>
                                setState(() => markers.removeAt(e.key)),
                            icon: const Icon(Icons.undo),
                          )
                        : null,
                  ),
                ),
                const Divider(),
                const Text('الصور المطلوبة لاعتماد الفحص'),
                ...['front', 'back', 'left', 'right', 'interior', 'damage'].map(
                  (v) => ListTile(
                    title: Text(inspectionViews[v]!),
                    subtitle: Text(
                      '${media.where((m) => m['kind'] == v).length} صور محفوظة',
                    ),
                    trailing: editable
                        ? IconButton(
                            tooltip: 'إضافة صورة',
                            onPressed: busy ? null : () => upload(v),
                            icon: const Icon(Icons.add_a_photo),
                          )
                        : null,
                  ),
                ),
                CheckboxListTile(
                  value: consent,
                  onChanged: editable
                      ? (v) => setState(() => consent = v!)
                      : null,
                  title: const Text(
                    'تم إيضاح سجل الفحص للعميل والحصول على موافقته على التوقيع',
                  ),
                ),
                Text(
                  'التوقيعات المحفوظة: ${media.where((m) => m['kind'] == 'signature').length}',
                ),
                if (editable && media.every((m) => m['kind'] != 'signature'))
                  OutlinedButton(
                    onPressed: busy ? null : signature,
                    child: const Text('توقيع العميل على هذه الشاشة'),
                  ),
                TextField(
                  controller: unsigned,
                  enabled: editable,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    labelText: 'سبب تعذر التوقيع عند عدم وجود توقيع',
                  ),
                ),
                if (editable) ...[
                  FilledButton.tonal(
                    onPressed: busy ? null : () => run(save),
                    child: const Text('حفظ المسودة'),
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            await save();
                            await widget.client.rpc(
                              'approve_vehicle_inspection',
                              params: {
                                'p_inspection': widget.inspectionId,
                                'p_expected': inspection!['version'],
                              },
                            );
                            await load();
                          }),
                    child: const Text('اعتماد الفحص وحماية الأصل من التعديل'),
                  ),
                ],
              ],
            ),
    );
  }
}

class VehicleDamagePainter extends CustomPainter {
  final List<Map<String, dynamic>> markers;
  VehicleDamagePainter(this.markers);
  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * .2, 15, size.width * .6, size.height - 30),
      const Radius.circular(28),
    );
    canvas.drawRRect(body, Paint()..color = const Color(0xffe0e5ed));
    canvas.drawRRect(
      body,
      Paint()
        ..color = const Color(0xff162c4a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    for (final y in [.2, .7]) {
      canvas.drawRect(
        Rect.fromLTWH(size.width * .13, size.height * y, size.width * .12, 28),
        Paint()..color = Colors.grey.shade700,
      );
      canvas.drawRect(
        Rect.fromLTWH(size.width * .75, size.height * y, size.width * .12, 28),
        Paint()..color = Colors.grey.shade700,
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(size.width * .3, 45, size.width * .4, 70),
      Paint()..color = Colors.white,
    );
    for (final m in markers) {
      canvas.drawCircle(
        Offset(
          (m['x'] as num).toDouble() * size.width,
          (m['y'] as num).toDouble() * size.height,
        ),
        7,
        Paint()..color = Colors.red,
      );
    }
  }

  @override
  bool shouldRepaint(covariant VehicleDamagePainter oldDelegate) => true;
}

class SignatureCaptureDialog extends StatefulWidget {
  const SignatureCaptureDialog({super.key});
  @override
  State<SignatureCaptureDialog> createState() => _SignatureCaptureDialogState();
}

class _SignatureCaptureDialogState extends State<SignatureCaptureDialog> {
  final List<List<Offset>> strokes = [];
  Size size = const Size(360, 180);
  Future<void> export() async {
    if (strokes.fold<int>(0, (n, s) => n + s.length) < 2) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(2);
    SignaturePainter(strokes).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (size.width * 2).ceil(),
      (size.height * 2).ceil(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (mounted && data != null) {
      Navigator.pop(context, data.buffer.asUint8List());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('توقيع العميل'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'يوقّع العميل بنفسه بعد مراجعة الفحص. الصورة توثق التوقيع ولا تمثل شهادة توقيع رقمي مؤهل.',
          ),
          LayoutBuilder(
            builder: (c, constraints) {
              size = Size(constraints.maxWidth, 180);
              return GestureDetector(
                onPanStart: (d) =>
                    setState(() => strokes.add([d.localPosition])),
                onPanUpdate: (d) =>
                    setState(() => strokes.last.add(d.localPosition)),
                child: CustomPaint(
                  size: size,
                  painter: SignaturePainter(strokes),
                ),
              );
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(strokes.clear),
        child: const Text('مسح اللوحة'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(onPressed: export, child: const Text('حفظ التوقيع')),
    ],
  );
}

class SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  SignaturePainter(this.strokes);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (final stroke in strokes) {
      for (var n = 1; n < stroke.length; n++) {
        canvas.drawLine(stroke[n - 1], stroke[n], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant SignaturePainter oldDelegate) => true;
}
