import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hr_payroll.dart' show hrRequestId;

abstract class RecruitmentGateway {
  Future<Map<String, dynamic>> action(String action, Map<String, dynamic> data);
  Future<void> uploadCv(String applicationId, String token, Uint8List bytes) =>
      throw UnsupportedError('CV upload unavailable');
  Future<String> downloadCv(String applicationId) =>
      throw UnsupportedError('CV download unavailable');
}

class SupabaseRecruitmentGateway extends RecruitmentGateway {
  SupabaseRecruitmentGateway(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
      'recruitment_action',
      params: {'p_action': action, 'p_data': data},
    ) as Map,
  );
  @override
  Future<void> uploadCv(
    String applicationId,
    String token,
    Uint8List bytes,
  ) async {
    final response = await client.functions.invoke(
      'recruitment-cv',
      body: bytes,
      headers: {
        'Content-Type': 'application/pdf',
        'x-application-id': applicationId,
        'x-upload-token': token,
      },
    );
    if (response.status != 200 ||
        (response.data as Map?)?['state'] != 'quarantined_unscanned') {
      throw Exception('CV upload did not complete');
    }
  }

  @override
  Future<String> downloadCv(String applicationId) async {
    final response = await client.functions.invoke(
      'recruitment-cv',
      body: {'action': 'download', 'application_id': applicationId},
    );
    if (response.status != 200) {
      throw Exception('CV download unavailable');
    }
    final path = (response.data as Map)['signed_path'] as String;
    final relative = Uri.parse(path);
    if (relative.hasScheme ||
        relative.hasAuthority ||
        !RegExp(
          r'^/object/sign/recruitment-cv-quarantine/[0-9a-f-]{36}/[0-9a-f]{64}\.pdf$',
        ).hasMatch(relative.path)) {
      throw Exception('Invalid attachment path');
    }
    return '${client.storage.url.replaceAll(RegExp(r'/+$'), '')}$path';
  }
}

class RecruitmentCvFile {
  const RecruitmentCvFile({
    required this.name,
    required this.size,
    required this.stream,
  });
  final String name;
  final int size;
  final Stream<List<int>> stream;
}

Future<RecruitmentCvFile?> pickRecruitmentCv() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['pdf'],
  );
  if (file == null) {
    return null;
  }
  final size = await file.length();
  if (size == null || size < 16 || size > 2097152) {
    throw Exception('Invalid PDF size');
  }
  return RecruitmentCvFile(
    name: file.name,
    size: size,
    stream: file.readAsByteStream(),
  );
}

class RecruitmentScreen extends StatefulWidget {
  const RecruitmentScreen({
    super.key,
    required this.client,
    this.owner = false,
    this.gateway,
    this.cvPicker,
  });
  final SupabaseClient client;
  final bool owner;
  final RecruitmentGateway? gateway;
  final Future<RecruitmentCvFile?> Function()? cvPicker;
  @override
  State<RecruitmentScreen> createState() => _RecruitmentScreenState();
}

class _RecruitmentScreenState extends State<RecruitmentScreen> {
  late final RecruitmentGateway api =
      widget.gateway ?? SupabaseRecruitmentGateway(widget.client);
  Map<String, dynamic>? data;
  String? error, receipt, pendingSignature, pendingId;
  bool busy = false;
  Uint8List? pendingCv;
  String? cvApplication, cvToken;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String tr(String en, String arabic) => ar ? arabic : en;
  String status(String s) => tr(
    s,
    {
          'submitted': 'تم الاستلام',
          'interview': 'مقابلة',
          'accepted': 'مقبول',
          'rejected': 'مرفوض',
          'prepared': 'موظف غير نشط',
          'activated': 'موظف نشط',
        }[s] ??
        s,
  );
  List<Map<String, dynamic>> rows(String key) => ((data?[key] as List?) ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await api.action(widget.owner ? 'owner_read' : 'jobs', {});
      if (mounted) {
        setState(() {
          data = v;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
  }

  Future<void> _act(
    String action,
    Map<String, dynamic> inputs, {
    Uint8List? cv,
    String? token,
  }) async {
    setState(() {
      busy = true;
      error = null;
      receipt = null;
    });
    try {
      final signature = '$action:${jsonEncode(inputs)}';
      if (pendingSignature != signature) {
        pendingSignature = signature;
        pendingId = hrRequestId();
      }
      final v = await api.action(action, {'request_id': pendingId, ...inputs});
      pendingSignature = null;
      pendingId = null;
      await _load();
      if (mounted && action == 'submit') {
        setState(
          () => receipt =
              tr(
                'Application received. Reference: ',
                'تم استلام طلبك. رقم المرجع: ',
              ) +
              v['application_id'].toString(),
        );
        if (cv != null && token != null) {
          pendingCv = cv;
          cvToken = token;
          cvApplication = v['application_id'] as String;
          await _uploadCv();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> _uploadCv() async {
    if (pendingCv == null || cvToken == null || cvApplication == null) {
      return;
    }
    setState(() => busy = true);
    try {
      await api.uploadCv(cvApplication!, cvToken!, pendingCv!);
      pendingCv = null;
      cvToken = null;
      cvApplication = null;
      if (mounted) {
        setState(() {
          error = null;
          receipt =
              '${receipt ?? ''}\n${tr('CV received as a private unscanned attachment.', 'تم استلام السيرة الذاتية كمرفق خاص غير مفحوص.')}';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            'Application received. CV upload is incomplete; retry below.',
            'تم استلام الطلب. رفع السيرة الذاتية لم يكتمل؛ أعد المحاولة أدناه.',
          ),
        );
      }
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> _downloadCv(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Unscanned PDF attachment', 'مرفق PDF غير مفحوص')),
        content: Text(
          tr(
            'This applicant file is untrusted and has not been malware scanned. Download it only if you choose to handle an untrusted attachment. It is never previewed or automatically processed here.',
            'هذا الملف غير موثوق ولم يتم فحصه ضد البرمجيات الضارة. نزله فقط إذا اخترت التعامل مع مرفق غير موثوق. لا يتم عرضه أو معالجته تلقائياً هنا.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel', 'إلغاء')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Download attachment', 'تنزيل المرفق')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      final url = await api.downloadCv(id);
      if (!await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        throw Exception('Download unavailable');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            'CV download unavailable.',
            'تنزيل السيرة الذاتية غير متاح.',
          ),
        );
      }
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> _form(
    String title,
    String action,
    List<(String, String)> fields, {
    Map<String, dynamic> fixed = const {},
    List<Map<String, dynamic>> accounts = const [],
    bool branch = false,
  }) async {
    final controls = {for (final f in fields) f.$1: TextEditingController()};
    String? account, branchId, selectedToken, selectedName;
    Uint8List? selectedCv;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (accounts.isNotEmpty)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: tr(
                          'Verified matching account',
                          'حساب مطابق بوسيلة اتصال موثقة',
                        ),
                      ),
                      items: [
                        for (final a in accounts)
                          DropdownMenuItem(
                            value: a['id'] as String,
                            child: Text(
                              a['id'] as String,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => update(() => account = v),
                    ),
                  if (branch)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: tr('Branch', 'الفرع'),
                      ),
                      items: [
                        for (final b in rows('branches'))
                          DropdownMenuItem(
                            value: b['id'] as String,
                            child: Text(
                              b[ar ? 'name_ar' : 'name_en'] as String,
                            ),
                          ),
                      ],
                      onChanged: (v) => update(() => branchId = v),
                    ),
                  for (final f in fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: TextField(
                        controller: controls[f.$1],
                        maxLines:
                            f.$1.contains('details') ||
                                f.$1 == 'message' ||
                                f.$1 == 'owner_note'
                            ? 3
                            : 1,
                        decoration: InputDecoration(
                          labelText: f.$2,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  if (action == 'submit') ...[
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final picked =
                              await (widget.cvPicker ?? pickRecruitmentCv)();
                          if (picked == null || !ctx.mounted) {
                            return;
                          }
                          if (picked.size < 16 || picked.size > 2097152) {
                            throw Exception('Invalid PDF size');
                          }
                          final builder = BytesBuilder(copy: false);
                          var size = 0;
                          await for (final chunk in picked.stream) {
                            size += chunk.length;
                            if (size > 2097152) {
                              throw Exception('Invalid PDF size');
                            }
                            builder.add(chunk);
                          }
                          final bytes = builder.takeBytes();
                          if (!ctx.mounted) {
                            return;
                          }
                          if (size != picked.size ||
                              size < 16 ||
                              utf8.decode(
                                    bytes.sublist(0, 5),
                                    allowMalformed: true,
                                  ) !=
                                  '%PDF-') {
                            throw Exception('Invalid PDF');
                          }
                          update(() {
                            selectedCv = bytes;
                            selectedName = picked.name;
                            final random = Random.secure();
                            selectedToken =
                                List.generate(32, (_) => random.nextInt(256))
                                    .map(
                                      (v) =>
                                          v.toRadixString(16).padLeft(2, '0'),
                                    )
                                    .join();
                          });
                        } catch (_) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  tr(
                                    'Choose a readable PDF up to 2 MiB.',
                                    'اختر ملف PDF قابل للقراءة حتى 2 ميبيبايت.',
                                  ),
                                ),
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.attach_file),
                      label: Text(
                        tr(
                          'Attach optional PDF CV · up to 2 MiB',
                          'إرفاق سيرة ذاتية PDF اختياري · حتى 2 ميبيبايت',
                        ),
                      ),
                    ),
                    if (selectedName != null) Text(selectedName!),
                    if (selectedCv != null)
                      TextButton(
                        onPressed: () => update(() {
                          selectedCv = null;
                          selectedName = null;
                          selectedToken = null;
                        }),
                        child: Text(tr('Remove attachment', 'إزالة المرفق')),
                      ),
                  ],
                  if (action == 'prepare_employee')
                    Text(
                      tr(
                        'Compensation is in EGP. Preparation creates an inactive employee with no extra permissions. Activation is a separate owner action.',
                        'الأجر بالجنيه المصري. تجهيز الحساب ينشئ موظفاً غير نشط دون صلاحيات إضافية. التفعيل إجراء منفصل للمالك.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Cancel', 'إلغاء')),
            ),
            FilledButton(
              onPressed: () {
                if (branch && branchId == null ||
                    accounts.isNotEmpty && account == null) {
                  return;
                }
                final values = {
                  for (final e in controls.entries) e.key: e.value.text.trim(),
                };
                final optional = {'email', 'phone', 'message', 'owner_note'};
                if (values.entries.any(
                  (e) => !optional.contains(e.key) && e.value.isEmpty,
                )) {
                  return;
                }
                Navigator.pop(ctx, {
                  ...fixed,
                  ...values,
                  if (branch) 'branch_id': branchId,
                  if (accounts.isNotEmpty) 'user_id': account,
                });
              },
              child: Text(tr('Confirm', 'تأكيد')),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      await _act(
        action,
        {
          ...result,
          if (selectedToken != null)
            'cv_capability_hash': sha256
                .convert(utf8.encode(selectedToken!))
                .toString(),
        },
        cv: selectedCv,
        token: selectedToken,
      );
    }
  }

  Widget button(String en, String arabic, VoidCallback fn) =>
      FilledButton.tonal(
        onPressed: busy ? null : fn,
        child: Text(tr(en, arabic)),
      );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xffeef1f6),
    appBar: AppBar(
      backgroundColor: const Color(0xff102342),
      foregroundColor: Colors.white,
      title: Text(
        tr(
          widget.owner ? 'Recruitment review' : 'Careers',
          widget.owner ? 'إدارة التوظيف' : 'فرص العمل',
        ),
      ),
      actions: [
        IconButton(
          onPressed: busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: data == null && error == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          error!,
                          key: const Key('recruitment-error'),
                        ),
                      ),
                    ),
                  if (receipt != null)
                    Card(
                      color: Colors.green.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(receipt!),
                      ),
                    ),
                  if (widget.owner)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: button(
                        'Publish vacancy',
                        'نشر وظيفة',
                        () => _form(
                          tr('New vacancy', 'وظيفة جديدة'),
                          'save_job',
                          [
                            ('title_ar', tr('Arabic title', 'المسمى بالعربية')),
                            (
                              'title_en',
                              tr('English title', 'المسمى بالإنجليزية'),
                            ),
                            (
                              'details_ar',
                              tr(
                                'Arabic details and requirements',
                                'التفاصيل والمتطلبات بالعربية',
                              ),
                            ),
                            (
                              'details_en',
                              tr(
                                'English details and requirements',
                                'التفاصيل والمتطلبات بالإنجليزية',
                              ),
                            ),
                          ],
                          branch: true,
                          fixed: {'published': true},
                        ),
                      ),
                    ),
                  if (pendingCv != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: button(
                        'Retry CV upload',
                        'إعادة رفع السيرة الذاتية',
                        _uploadCv,
                      ),
                    ),
                  if (rows('jobs').isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        tr(
                          'No vacancies are currently listed.',
                          'لا توجد وظائف معلنة حالياً.',
                        ),
                      ),
                    ),
                  for (final j in rows('jobs'))
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${j[ar ? 'title_ar' : 'title_en']}',
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text('${j[ar ? 'details_ar' : 'details_en']}'),
                            const SizedBox(height: 12),
                            if (widget.owner)
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: button(
                                  j['published'] == true
                                      ? 'Close vacancy'
                                      : 'Reopen vacancy',
                                  j['published'] == true
                                      ? 'إغلاق الوظيفة'
                                      : 'إعادة فتح الوظيفة',
                                  () => _act('save_job', {
                                    'id': j['id'],
                                    'title_ar': j['title_ar'],
                                    'title_en': j['title_en'],
                                    'details_ar': j['details_ar'],
                                    'details_en': j['details_en'],
                                    'branch_id': j['branch_id'],
                                    'published': j['published'] != true,
                                  }),
                                ),
                              )
                            else
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: button(
                                  'Apply without an account',
                                  'التقديم دون حساب',
                                  () => _form(
                                    tr('Job application', 'طلب توظيف'),
                                    'submit',
                                    [
                                      ('name', tr('Full name', 'الاسم الكامل')),
                                      (
                                        'email',
                                        tr(
                                          'Email (optional if phone provided)',
                                          'البريد (اختياري عند إدخال الهاتف)',
                                        ),
                                      ),
                                      (
                                        'phone',
                                        tr(
                                          'International phone, e.g. +201234567890',
                                          'الهاتف الدولي مثل +201234567890',
                                        ),
                                      ),
                                      (
                                        'message',
                                        tr(
                                          'Experience and introduction (optional)',
                                          'الخبرة ونبذة عنك (اختياري)',
                                        ),
                                      ),
                                    ],
                                    fixed: {'job_id': j['id']},
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.owner)
                    for (final a in rows('applications'))
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${a['name']} · ${status(a['status'] as String)}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '${a[ar ? 'title_ar' : 'title_en']}\n${a['email'] ?? ''} ${a['phone'] ?? ''}\n${a['message']}',
                              ),
                              if (a['interview_at'] != null)
                                Text(
                                  '${tr('Interview UTC', 'المقابلة UTC')}: ${a['interview_at']}',
                                ),
                              if (a['owner_note'] != '')
                                Text('${a['owner_note']}'),
                              const SizedBox(height: 10),
                              if ((a['cv'] as Map?)?['state'] ==
                                  'quarantined_unscanned')
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: button(
                                    'Download unscanned CV',
                                    'تنزيل سيرة ذاتية غير مفحوصة',
                                    () => _downloadCv(a['id'] as String),
                                  ),
                                ),
                              if (![
                                'prepared',
                                'activated',
                              ].contains(a['status']))
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    button(
                                      'Interview',
                                      'مقابلة',
                                      () => _form(
                                        tr(
                                          'Schedule interview',
                                          'تحديد مقابلة',
                                        ),
                                        'review',
                                        [
                                          (
                                            'interview_at',
                                            tr(
                                              'UTC date/time, e.g. 2026-12-01T10:00Z',
                                              'التاريخ والوقت UTC مثل 2026-12-01T10:00Z',
                                            ),
                                          ),
                                          (
                                            'owner_note',
                                            tr(
                                              'Private note (optional)',
                                              'ملاحظة خاصة (اختياري)',
                                            ),
                                          ),
                                        ],
                                        fixed: {
                                          'application_id': a['id'],
                                          'status': 'interview',
                                        },
                                      ),
                                    ),
                                    button(
                                      'Accept candidate',
                                      'قبول المرشح',
                                      () => _act('review', {
                                        'application_id': a['id'],
                                        'status': 'accepted',
                                      }),
                                    ),
                                    button(
                                      'Reject',
                                      'رفض',
                                      () => _act('review', {
                                        'application_id': a['id'],
                                        'status': 'rejected',
                                      }),
                                    ),
                                  ],
                                ),
                              if (a['status'] == 'accepted')
                                Builder(
                                  builder: (context) {
                                    final accounts =
                                        ((a['verified_accounts'] as List?) ??
                                                [])
                                            .map(
                                              (v) => Map<String, dynamic>.from(
                                                v as Map,
                                              ),
                                            )
                                            .toList();
                                    return accounts.isEmpty
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              top: 10,
                                            ),
                                            child: Text(
                                              tr(
                                                'Employee preparation requires an existing account with the same verified email or phone. No account or invitation is created here.',
                                                'يتطلب تجهيز الموظف حساباً موجوداً بنفس البريد أو الهاتف الموثق. لا يتم إنشاء حساب أو إرسال دعوة هنا.',
                                              ),
                                            ),
                                          )
                                        : Align(
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                            child: button(
                                              'Prepare inactive employee',
                                              'تجهيز موظف غير نشط',
                                              () => _form(
                                                tr(
                                                  'Prepare inactive employee · EGP',
                                                  'تجهيز موظف غير نشط · جنيه مصري',
                                                ),
                                                'prepare_employee',
                                                [
                                                  (
                                                    'salary',
                                                    tr(
                                                      'Explicit base salary per payroll period',
                                                      'الراتب الأساسي المحدد لكل فترة',
                                                    ),
                                                  ),
                                                  (
                                                    'commission_percent',
                                                    tr(
                                                      'Explicit commission percentage',
                                                      'نسبة العمولة المحددة',
                                                    ),
                                                  ),
                                                  (
                                                    'starts_on',
                                                    tr(
                                                      'Employment starts YYYY-MM-DD',
                                                      'بداية التوظيف YYYY-MM-DD',
                                                    ),
                                                  ),
                                                ],
                                                accounts: accounts,
                                                branch: true,
                                                fixed: {
                                                  'application_id': a['id'],
                                                  'currency': 'EGP',
                                                },
                                              ),
                                            ),
                                          );
                                  },
                                ),
                              if (a['status'] == 'prepared')
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: button(
                                    'Activate employee now',
                                    'تفعيل الموظف الآن',
                                    () => _act('activate_employee', {
                                      'application_id': a['id'],
                                    }),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
      ),
    ),
  );
}
