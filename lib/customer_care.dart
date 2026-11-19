import 'customer_visuals.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'delivery_support.dart';
import 'branch_settings.dart';

String? safeImageMime(Uint8List bytes, {int maxBytes = 5242880}) {
  if (bytes.isEmpty || bytes.length > maxBytes) return null;
  if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return 'image/jpeg';
  }
  return null;
}

Future<String?> uploadCareImage(
  SupabaseClient client,
  String bucket,
  String prefix,
) async {
  final result = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['jpg', 'jpeg', 'png'],
  );
  if (result == null) return null;
  final size = await result.length();
  if (size == null || size > (bucket == 'staff-photos' ? 3145728 : 5242880)) {
    throw ArgumentError('Image too large');
  }
  final bytes = await result.readAsBytes();
  final mime = safeImageMime(
    bytes,
    maxBytes: bucket == 'staff-photos' ? 3145728 : 5242880,
  );
  if (mime == null) throw ArgumentError('JPEG/PNG within size limit required');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > 16000000 ||
        descriptor.width > 8000 ||
        descriptor.height > 8000) {
      throw ArgumentError('Image dimensions too large');
    }
    codec = await descriptor.instantiateCodec(targetWidth: 128);
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }

  final path =
      '$prefix/${newOrderRequestId()}.${mime == 'image/png' ? 'png' : 'jpg'}';
  await client.storage
      .from(bucket)
      .uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(contentType: mime, upsert: false),
      );
  return path;
}

const complaintLabels = {
  'new': 'جديدة',
  'under_review': 'قيد المراجعة',
  'in_progress': 'جارٍ الحل',
  'resolved': 'تم الحل',
  'closed': 'مغلقة',
};
List<String> complaintNext(String state) => switch (state) {
  'new' => ['under_review'],
  'under_review' => ['in_progress'],
  'in_progress' => ['resolved'],
  'resolved' => ['in_progress', 'closed'],
  _ => [],
};

class ComplaintsScreen extends StatefulWidget {
  final SupabaseClient client;
  final String? role;
  const ComplaintsScreen({super.key, required this.client, this.role});
  @override
  State<ComplaintsScreen> createState() => _ComplaintsScreenState();
}

class _ComplaintsScreenState extends State<ComplaintsScreen> {
  List<Map<String, dynamic>> complaints = [],
      bookings = [],
      orders = [],
      staff = [];
  bool loading = true, busy = false;
  String? error;
  String search = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      complaints = List<Map<String, dynamic>>.from(
        await widget.client
            .from('customer_complaints')
            .select()
            .order('created_at', ascending: false)
            .limit(100),
      );
      if (widget.role == null) {
        bookings = List<Map<String, dynamic>>.from(
          await widget.client
              .from('bookings')
              .select('id,service_name,booking_date'),
        );
        orders = List<Map<String, dynamic>>.from(
          await widget.client
              .from('business_orders')
              .select('order_id,order_number'),
        );
      } else if (widget.role == 'owner' || widget.role == 'manager') {
        staff = List<Map<String, dynamic>>.from(
          await widget.client
              .from('staff_profiles')
              .select('user_id,full_name')
              .eq('is_active', true),
        );
      }
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
          error = 'تعذر تحميل الشكاوى.';
        });
      }
    }
  }

  Future<void> create() async {
    final visits = [
      ...bookings.map(
        (b) => {
          'key': 'b:${b['id']}',
          'label': '${b['service_name']} · ${b['booking_date']}',
        },
      ),
      ...orders.map(
        (o) => {
          'key': 'o:${o['order_id']}',
          'label': 'طلب ${o['order_number']}',
        },
      ),
    ];
    if (visits.isEmpty) return;
    String visit = visits.first['key']!;
    bool photo = false;
    final details = TextEditingController();
    final request = newOrderRequestId();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: const Text('شكوى مرتبطة بزيارة أو طلب'),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: visit,
                    items: visits
                        .map(
                          (v) => DropdownMenuItem(
                            value: v['key'],
                            child: Text(
                              v['label']!,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => update(() => visit = v!),
                  ),
                  TextField(
                    controller: details,
                    maxLines: 5,
                    maxLength: 4000,
                    decoration: const InputDecoration(
                      labelText: 'تفاصيل الشكوى (10 أحرف على الأقل)',
                    ),
                  ),
                  CheckboxListTile(
                    value: photo,
                    onChanged: (v) => update(() => photo = v!),
                    title: const Text(
                      'إرفاق صورة اختيارية بعد حفظ الشكوى (JPEG/PNG حتى 5MB)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('إرسال الشكوى'),
            ),
          ],
        ),
      ),
    );
    final text = details.text.trim();
    details.dispose();
    if (accepted != true) return;
    setState(() => busy = true);
    try {
      final result = await widget.client.rpc(
        'create_customer_complaint',
        params: {
          'p_request': request,
          'p_booking': visit.startsWith('b:') ? visit.substring(2) : null,
          'p_order': visit.startsWith('o:') ? visit.substring(2) : null,
          'p_details': text,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم استلام الشكوى ${result['reference']}')),
        );
      }
      if (photo) {
        try {
          await uploadCareImage(
            widget.client,
            'complaint-files',
            '${widget.client.auth.currentUser!.id}/${result['complaint_id']}',
          );
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'حُفظت الشكوى، وتعذر رفع الصورة. يمكنك إضافتها من تفاصيل الشكوى.',
                ),
              ),
            );
          }
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الإرسال. تحقق من التفاصيل وملكية الزيارة.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await load();
  }

  Future<void> detail(Map<String, dynamic> complaint) async {
    try {
      final events = await widget.client
          .from('customer_complaint_events')
          .select('status,note,created_at,is_internal')
          .eq('complaint_id', complaint['complaint_id'])
          .order('created_at');
      final prefix = '${complaint['customer_id']}/${complaint['complaint_id']}';
      final files = await widget.client.storage
          .from('complaint-files')
          .list(path: prefix);
      final urls = <String>[];
      for (final file in files) {
        if (file.id != null) {
          urls.add(
            await widget.client.storage
                .from('complaint-files')
                .createSignedUrl('$prefix/${file.name}', 300),
          );
        }
      }
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(complaint['reference']),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(complaint['details']),
                  ...events.map(
                    (e) => ListTile(
                      title: Text(
                        '${complaintLabels[e['status']]}${e['is_internal'] ? ' · داخلي' : ''}',
                      ),
                      subtitle: Text('${e['note']}\n${e['created_at']}'),
                    ),
                  ),
                  ...urls.map(
                    (url) => GestureDetector(
                      onTap: () => showDialog(
                        context: c,
                        builder: (_) => Dialog(
                          child: InteractiveViewer(child: Image.network(url)),
                        ),
                      ),
                      child: Image.network(url, height: 180),
                    ),
                  ),
                  if (widget.role == null)
                    OutlinedButton(
                      onPressed: () async {
                        try {
                          await uploadCareImage(
                            widget.client,
                            'complaint-files',
                            prefix,
                          );
                          if (c.mounted) Navigator.pop(c);
                        } catch (_) {
                          if (c.mounted) {
                            ScaffoldMessenger.of(c).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'تعذر رفع الصورة. استخدم JPEG أو PNG حتى 5MB.',
                                ),
                              ),
                            );
                          }
                        }
                      },
                      child: const Text('إضافة صورة'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تحميل تفاصيل الشكوى أو الصور الخاصة.'),
          ),
        );
      }
    }
  }

  Future<void> manage(Map<String, dynamic> f) async {
    String status = f['status'];
    String? assigned = f['assigned_to'];
    bool internal = false;
    final note = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(f['reference']),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: status,
                items: [status, ...complaintNext(status)]
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(complaintLabels[s]!),
                      ),
                    )
                    .toList(),
                onChanged: (s) => update(() => status = s!),
              ),
              if (staff.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: staff.any((s) => s['user_id'] == assigned)
                      ? assigned
                      : null,
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('بدون تكليف'),
                    ),
                    ...staff.map(
                      (s) => DropdownMenuItem(
                        value: s['user_id'] as String,
                        child: Text(s['full_name']),
                      ),
                    ),
                  ],
                  onChanged: (v) => update(() => assigned = v),
                ),
              TextField(
                controller: note,
                maxLength: 2000,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'الإجراء أو الرد (5 أحرف على الأقل)',
                ),
              ),
              CheckboxListTile(
                value: internal,
                onChanged: (v) => update(() => internal = v!),
                title: const Text('ملاحظة إدارية داخلية'),
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
              child: const Text('حفظ الإجراء'),
            ),
          ],
        ),
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (accepted != true) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'update_customer_complaint',
        params: {
          'p_complaint': f['complaint_id'],
          'p_expected': f['status'],
          'p_status': status,
          'p_assigned': assigned,
          'p_note': text,
          'p_internal': internal,
        },
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر التحديث. تحقق من الحالة وصلاحية الفرع والتكليف.',
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
    title: customerText(context, 'الشكاوى والدعم', 'Complaints & support'),
    selected: 4,
    appBar: AppBar(
      title: const Text('الشكاوى وخدمة العملاء'),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    floatingActionButton: widget.role == null
        ? FloatingActionButton.extended(
            onPressed: busy ? null : create,
            icon: const Icon(Icons.add),
            label: const Text('شكوى جديدة'),
          )
        : null,
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              if (error != null) Text(error!),
              if (busy) const LinearProgressIndicator(),
              TextField(
                onChanged: (v) => setState(() => search = v),
                decoration: const InputDecoration(
                  labelText: 'بحث بالمرجع أو الحالة أو التفاصيل',
                ),
              ),
              if (complaints.isEmpty) const Text('لا توجد شكاوى.'),
              ...complaints
                  .where(
                    (c) =>
                        '${c['reference']} ${c['details']} ${complaintLabels[c['status']]}'
                            .contains(search),
                  )
                  .map(
                    (f) => Card(
                      child: ListTile(
                        title: Text(
                          '${f['reference']} · ${complaintLabels[f['status']]}',
                        ),
                        subtitle: Text(
                          f['details'],
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => detail(f),
                        trailing: widget.role == null
                            ? null
                            : IconButton(
                                tooltip: 'تسجيل إجراء',
                                icon: const Icon(Icons.edit_note),
                                onPressed: busy ? null : () => manage(f),
                              ),
                      ),
                    ),
                  ),
            ],
          ),
  );
}

class EmployeeReviewsScreen extends StatefulWidget {
  final SupabaseClient client;
  final bool owner;
  const EmployeeReviewsScreen({
    super.key,
    required this.client,
    this.owner = false,
  });
  @override
  State<EmployeeReviewsScreen> createState() => _EmployeeReviewsScreenState();
}

class _EmployeeReviewsScreenState extends State<EmployeeReviewsScreen> {
  List<Map<String, dynamic>> directory = [],
      bookings = [],
      reviews = [],
      staff = [],
      branches = [],
      profiles = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      directory = List<Map<String, dynamic>>.from(
        await widget.client.rpc(
          'employee_directory',
          params: {'p_branch': BranchSelection.current},
        ),
      );
      if (widget.owner) {
        reviews = List<Map<String, dynamic>>.from(
          await widget.client
              .from('employee_service_reviews')
              .select()
              .order('created_at', ascending: false)
              .limit(100),
        );
        staff = List<Map<String, dynamic>>.from(
          await widget.client
              .from('staff_profiles')
              .select('user_id,full_name')
              .eq('is_active', true),
        );
        branches = List<Map<String, dynamic>>.from(
          await widget.client.from('business_branches').select(),
        );
        profiles = List<Map<String, dynamic>>.from(
          await widget.client.from('employee_public_profiles').select(),
        );
      } else if (widget.client.auth.currentUser != null) {
        bookings = List<Map<String, dynamic>>.from(
          await widget.client
              .from('bookings')
              .select('id,service_name,booking_date')
              .eq('customer_id', widget.client.auth.currentUser!.id)
              .eq('status', 'completed'),
        );
      }
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
          error = 'تعذر تحميل التقييمات.';
        });
      }
    }
  }

  Future<T?> _careDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) => widget.owner
      ? showDialog<T>(context: context, builder: builder)
      : showCustomerDialog<T>(context: context, builder: builder);
  Future<void> rate(Map<String, dynamic> booking) async {
    try {
      final people = List<Map<String, dynamic>>.from(
        await widget.client.rpc(
          'review_targets',
          params: {'p_booking': booking['id']},
        ),
      );
      if (!mounted) return;
      await _careDialog(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(
            customerText(
              context,
              'قيّم من خدمك · التعديل متاح 7 أيام',
              'Rate your care team · Editable for 7 days',
            ),
          ),
          children: people
              .map(
                (p) => ListTile(
                  title: Text(p['display_name']),
                  subtitle: Text(
                    p['stars'] == null ? 'لم يُقيّم بعد' : '${p['stars']} / 5',
                  ),
                  enabled: p['editable'] == true,
                  onTap: () async {
                    Navigator.pop(c);
                    int stars = (p['stars'] as num?)?.toInt() ?? 5;
                    final comment = TextEditingController(
                      text: p['comment'] ?? '',
                    );
                    final ok = await _careDialog<bool>(
                      context: context,
                      builder: (d) => StatefulBuilder(
                        builder: (d, update) => AlertDialog(
                          title: Text(p['display_name']),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DropdownButton<int>(
                                value: stars,
                                items: List.generate(
                                  5,
                                  (i) => DropdownMenuItem(
                                    value: i + 1,
                                    child: Text('${i + 1} ★'),
                                  ),
                                ),
                                onChanged: (v) => update(() => stars = v!),
                              ),
                              TextField(
                                controller: comment,
                                maxLength: 1000,
                                maxLines: 3,
                                decoration: InputDecoration(
                                  labelText: customerText(
                                    context,
                                    'تعليق اختياري يخضع للمراجعة',
                                    'Optional comment, subject to moderation',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(d, false),
                              child: Text(
                                customerText(context, 'إلغاء', 'Cancel'),
                              ),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(d, true),
                              child: Text(
                                customerText(
                                  context,
                                  'حفظ التقييم',
                                  'Save review',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                    final text = comment.text;
                    comment.dispose();
                    if (ok == true) {
                      await widget.client.rpc(
                        'save_service_review',
                        params: {
                          'p_booking': booking['id'],
                          'p_employee': p['employee_id'],
                          'p_stars': stars,
                          'p_comment': text,
                        },
                      );
                      await load();
                    }
                  },
                ),
              )
              .toList(),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تعذر حفظ التقييم. يلزم أن تكون الخدمة مكتملة والموظف مشاركًا فيها.',
            ),
          ),
        );
      }
    }
  }

  Future<void> moderate(Map<String, dynamic> r) async {
    final reason = TextEditingController();
    bool publish = r['comment_published'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(
            customerText(
              context,
              'مراجعة التعليق دون تغيير النجوم',
              'Moderate comment without changing stars',
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(r['comment']),
              SwitchListTile(
                value: publish,
                onChanged: (v) => update(() => publish = v),
                title: Text(
                  customerText(context, 'نشر التعليق', 'Publish comment'),
                ),
              ),
              TextField(
                controller: reason,
                decoration: InputDecoration(labelText: 'سبب المراجعة'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(customerText(context, 'إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(customerText(context, 'حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );
    final text = reason.text;
    reason.dispose();
    if (ok == true) {
      try {
        await widget.client.rpc(
          'moderate_service_review',
          params: {
            'p_review': r['review_id'],
            'p_publish': publish,
            'p_reason': text,
          },
        );
        await load();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('تعذر حفظ المراجعة. يلزم سبب وصلاحية المالك.'),
            ),
          );
        }
      }
    }
  }

  Future<void> profile(Map<String, dynamic> person) async {
    final existing = profiles
        .where((p) => p['user_id'] == person['user_id'])
        .firstOrNull;
    final name = TextEditingController(
          text: existing?['display_name'] ?? person['full_name'],
        ),
        title = TextEditingController(text: existing?['job_title'] ?? '');
    String branch = existing?['branch_id'] ?? branches.first['branch_id'];
    bool published = existing?['is_published'] ?? false,
        consent = existing?['photo_consent'] ?? false;
    String? photo = existing?['photo_path'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: const Text('الملف العام وصورة الموظف'),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: InputDecoration(labelText: 'الاسم المعروض'),
                  ),
                  TextField(
                    controller: title,
                    decoration: InputDecoration(labelText: 'المسمى الوظيفي'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: branch,
                    items: branches
                        .map(
                          (b) => DropdownMenuItem(
                            value: b['branch_id'] as String,
                            child: Text(branchName(b, context)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => update(() => branch = v!),
                  ),
                  SwitchListTile(
                    value: published,
                    onChanged: (v) => update(() => published = v),
                    title: const Text('نشر الملف العام'),
                  ),
                  CheckboxListTile(
                    value: consent,
                    onChanged: (v) => update(() => consent = v!),
                    title: const Text('تم الحصول على موافقة الموظف لنشر صورته'),
                  ),
                  if (existing?['pending_photo_path'] != null)
                    TextButton(
                      onPressed: () =>
                          update(() => photo = existing!['pending_photo_path']),
                      child: const Text('اعتماد الصورة المقترحة من الموظف'),
                    ),
                  OutlinedButton(
                    onPressed: () async {
                      try {
                        final path = await uploadCareImage(
                          widget.client,
                          'staff-photos',
                          person['user_id'],
                        );
                        if (path != null && c.mounted) {
                          update(() => photo = path);
                        }
                      } catch (_) {
                        if (c.mounted) {
                          ScaffoldMessenger.of(c).showSnackBar(
                            SnackBar(
                              content: Text('استخدم JPEG أو PNG حتى 3MB.'),
                            ),
                          );
                        }
                      }
                    },
                    child: const Text('رفع صورة معتمدة'),
                  ),
                  if (photo != null)
                    const Text('صورة محفوظة · لا تُنشر دون موافقة واعتماد'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(customerText(context, 'إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('اعتماد وحفظ'),
            ),
          ],
        ),
      ),
    );
    final n = name.text, t = title.text;
    name.dispose();
    title.dispose();
    if (ok == true) {
      try {
        await widget.client.rpc(
          'manage_employee_profile',
          params: {
            'p_user': person['user_id'],
            'p_name': n,
            'p_title': t,
            'p_branch': branch,
            'p_publish': published,
            'p_photo': photo,
            'p_consent': consent,
          },
        );
        await load();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'تعذر الاعتماد. تحقق من عضوية الموظف في الفرع والصورة.',
              ),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => CustomerAdaptiveFrame(
    enabled: !widget.owner,
    title: customerText(
      context,
      'التقييمات وفريق العناية',
      'Reviews & care team',
    ),
    selected: 4,
    appBar: AppBar(
      title: Text(
        customerText(context, 'فريق العمل والتقييمات', 'Care team & reviews'),
      ),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (error != null) Text(error!),
              if (widget.owner) ...[
                Text(
                  customerText(
                    context,
                    'إدارة الملفات العامة والصور',
                    'Public profiles and photos',
                  ),
                ),
                ...staff.map(
                  (s) => ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(s['full_name']),
                    trailing: const Icon(Icons.edit),
                    onTap: () => profile(s),
                  ),
                ),
                const Divider(),
                ...reviews.map(
                  (r) => ListTile(
                    title: Text('${r['stars']} ★ · ${r['comment']}'),
                    subtitle: Text(
                      '${r['created_at']} · ${r['comment_published'] ? 'منشور' : 'غير منشور'}',
                    ),
                    onTap: () => moderate(r),
                  ),
                ),
              ],
              ...bookings.map(
                (b) => Card(
                  child: ListTile(
                    title: Text('${b['service_name']} · ${b['booking_date']}'),
                    trailing: const Icon(Icons.star_outline),
                    onTap: () => rate(b),
                  ),
                ),
              ),
              ...directory.map(
                (p) => CustomerPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          if (p['photo_path'] != null)
                            FutureBuilder<String>(
                              future: widget.client.storage
                                  .from('staff-photos')
                                  .createSignedUrl(p['photo_path'], 300),
                              builder: (c, s) => ClipOval(
                                child: s.hasData
                                    ? Image.network(
                                        s.data!,
                                        width: 64,
                                        height: 64,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, e, stack) =>
                                            const CircleAvatar(
                                              radius: 32,
                                              backgroundColor: customerBlue,
                                              child: Icon(
                                                Icons.person_outline,
                                                color: Colors.white,
                                              ),
                                            ),
                                      )
                                    : const CircleAvatar(
                                        radius: 32,
                                        backgroundColor: customerBlue,
                                        child: Icon(
                                          Icons.person_outline,
                                          color: Colors.white,
                                        ),
                                      ),
                              ),
                            )
                          else
                            const CircleAvatar(
                              radius: 32,
                              backgroundColor: customerBlue,
                              child: Icon(
                                Icons.person_outline,
                                color: Colors.white,
                              ),
                            ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${p['display_name']}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  '${p['job_title'] ?? ''}',
                                  style: const TextStyle(color: customerIce),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${p['average_stars'] ?? '—'} / 5 · ${p['review_count']} ${customerText(context, 'تقييم', 'reviews')}',
                                  style: const TextStyle(
                                    color: customerGold,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      for (final comment in p['comments'] as List? ?? [])
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${comment['stars']} ★',
                                style: const TextStyle(color: customerGold),
                              ),
                              Text(
                                '${comment['comment']}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
  );
}

Future<void> proposeEmployeePhoto(
  BuildContext context,
  SupabaseClient client,
) async {
  try {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final consent = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          ar ? 'اقتراح صورة لدليل الموظفين' : 'Suggest a staff directory photo',
        ),
        content: Text(
          ar
              ? 'أوافق على استخدام الصورة في دليل الموظفين بعد مراجعة الإدارة. لن تظهر للعملاء قبل الاعتماد.'
              : 'I agree to suggest this photo for the staff directory. It will not be visible to customers before management approval.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(ar ? 'أوافق وأختار صورة' : 'Agree and choose photo'),
          ),
        ],
      ),
    );
    if (consent != true || !context.mounted) return;
    final path = await uploadCareImage(client, 'staff-photos', uid);
    if (path == null || !context.mounted) return;
    await client.rpc(
      'propose_employee_photo',
      params: {'p_path': path, 'p_consent': true},
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ar
                ? 'تم إرسال الصورة للمراجعة.'
                : 'Photo sent for management review.',
          ),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تعذر إرسال الصورة. تحقق من الصيغة والاتصال والصلاحية.',
          ),
        ),
      );
    }
  }
}
