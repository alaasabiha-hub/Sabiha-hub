import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_campaign_media.dart';
import 'workflow.dart' show newOrderRequestId;

abstract interface class OwnerCampaignGateway {
  String? get actorId;
  Future<List<Map<String, dynamic>>> listCampaigns();
  Future<List<Map<String, dynamic>>> listOffers();
  Future<List<Map<String, dynamic>>> listBranches();
  Future<List<Map<String, dynamic>>> listRuns(String campaignId);
  Future<String> uploadImage(NotificationCampaignImage image);
  Future<void> insertCampaign(Map<String, dynamic> row);
  Future<void> updateCampaign(String campaignId, Map<String, dynamic> row);
}

class SupabaseOwnerCampaignGateway implements OwnerCampaignGateway {
  SupabaseOwnerCampaignGateway(this.client)
    : actorId = client.auth.currentUser?.id;
  final SupabaseClient client;
  @override
  final String? actorId;

  void _check() {
    if (actorId == null || client.auth.currentUser?.id != actorId) {
      throw StateError('Owner session changed');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listCampaigns() async {
    _check();
    final rows = await client
        .from('marketing_campaigns')
        .select()
        .order('updated_at', ascending: false)
        .limit(100);
    _check();
    return List<Map<String, dynamic>>.from(rows);
  }

  @override
  Future<List<Map<String, dynamic>>> listOffers() async {
    _check();
    final rows = await client
        .from('business_offers')
        .select('offer_id,name,offer_type,is_active,is_public')
        .order('name')
        .limit(200);
    _check();
    return List<Map<String, dynamic>>.from(rows);
  }

  @override
  Future<List<Map<String, dynamic>>> listBranches() async {
    _check();
    final rows = await client
        .from('business_branches')
        .select('branch_id,name_ar,name_en')
        .eq('is_active', true)
        .order('name_ar')
        .limit(100);
    _check();
    return List<Map<String, dynamic>>.from(rows);
  }

  @override
  Future<List<Map<String, dynamic>>> listRuns(String campaignId) async {
    _check();
    final rows = await client
        .from('marketing_campaign_runs')
        .select(
          'run_id,scheduled_for,status,started_at,finished_at,recipient_count,accepted_count,failed_count,in_app_count,error_message',
        )
        .eq('campaign_id', campaignId)
        .order('scheduled_for', ascending: false)
        .limit(30);
    _check();
    return List<Map<String, dynamic>>.from(rows);
  }

  @override
  Future<String> uploadImage(NotificationCampaignImage image) async {
    _check();
    final path = 'campaigns/${newOrderRequestId()}.${image.extension}';
    await client.storage
        .from('customer-notification-media')
        .uploadBinary(
          path,
          Uint8List.fromList(image.bytes),
          fileOptions: FileOptions(
            contentType: image.contentType,
            upsert: false,
          ),
        );
    _check();
    return client.storage
        .from('customer-notification-media')
        .getPublicUrl(path);
  }

  @override
  Future<void> insertCampaign(Map<String, dynamic> row) async {
    _check();
    await client.from('marketing_campaigns').insert(row);
    _check();
  }

  @override
  Future<void> updateCampaign(
    String campaignId,
    Map<String, dynamic> row,
  ) async {
    _check();
    await client
        .from('marketing_campaigns')
        .update(row)
        .eq('campaign_id', campaignId);
    _check();
  }
}

/// Owner-only campaign authoring and scheduling. It never calls a dispatcher.
class OwnerNotificationsScreen extends StatefulWidget {
  const OwnerNotificationsScreen({super.key, this.client, this.gateway})
    : assert(client != null || gateway != null);
  final SupabaseClient? client;
  final OwnerCampaignGateway? gateway;

  @override
  State<OwnerNotificationsScreen> createState() =>
      _OwnerNotificationsScreenState();
}

class _OwnerNotificationsScreenState extends State<OwnerNotificationsScreen> {
  late OwnerCampaignGateway _gateway;
  String? _actor;
  bool _busy = false;
  bool _uploadingImage = false;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _offers = [];
  List<Map<String, dynamic>> _branches = [];
  Map<String, dynamic>? _selected;
  List<Map<String, dynamic>> _runs = [];
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _titleEn = TextEditingController();
  final _bodyEn = TextEditingController();
  final _image = TextEditingController();
  final _days = TextEditingController(text: '30');
  final _points = TextEditingController(text: '1');
  final _customerIds = TextEditingController();
  final _deepLink = TextEditingController(text: '/offers');
  String _segment = 'all';
  String _recurrence = 'once';
  String? _offerId;
  String? _branchId;
  DateTime _scheduled = DateTime.now().add(const Duration(hours: 1));
  int _generation = 0;

  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String ar, String en) => _ar ? ar : en;
  bool get _current =>
      mounted &&
      (widget.client == null || widget.client!.auth.currentUser?.id == _actor);

  @override
  void initState() {
    super.initState();
    _actor = widget.client?.auth.currentUser?.id;
    _gateway = widget.gateway ?? SupabaseOwnerCampaignGateway(widget.client!);
    load();
  }

  @override
  void dispose() {
    _generation++;
    for (final c in [
      _title,
      _body,
      _titleEn,
      _bodyEn,
      _image,
      _days,
      _points,
      _customerIds,
      _deepLink,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await _gateway.listCampaigns();
      List<Map<String, dynamic>> offers = [];
      List<Map<String, dynamic>> branches = [];
      try {
        offers = await _gateway.listOffers();
      } catch (_) {
        // Campaign authoring remains available if the optional offer catalogue
        // is unavailable; a campaign cannot claim an offer relationship then.
      }
      try {
        branches = await _gateway.listBranches();
      } catch (_) {
        // Other audience segments remain available if branch reads are denied.
      }
      if (!_current || generation != _generation) return;
      setState(() {
        _rows = rows;
        _offers = offers;
        _branches = branches;
        if (_selected != null) {
          _selected = rows.cast<Map<String, dynamic>?>().firstWhere(
            (r) => r?['campaign_id'] == _selected?['campaign_id'],
            orElse: () => null,
          );
        }
      });
      if (_selected?['campaign_id'] is String) {
        await loadRuns(_selected!['campaign_id'] as String);
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(
          () => _error = t(
            'تعذر تحميل الحملات. تحقق من صلاحية المالك والاتصال.',
            'Campaigns could not be loaded. Check owner access and connection.',
          ),
        );
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> loadRuns(String id) async {
    try {
      final result = await _gateway.listRuns(id);
      if (_current && mounted && _selected?['campaign_id'] == id) {
        setState(() => _runs = result);
      }
    } catch (_) {
      if (_current && mounted) setState(() => _runs = []);
    }
  }

  Future<void> uploadCampaignImage() async {
    if (_busy || _uploadingImage || !_current) return;
    List<PlatformFile> selected;
    try {
      selected = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );
    } catch (_) {
      if (_current) {
        setState(
          () => _error = t(
            'تعذر فتح منتقي الصور على هذا الجهاز.',
            'Could not open the image picker on this device.',
          ),
        );
      }
      return;
    }
    if (selected.isEmpty || !_current) return;
    NotificationCampaignImage image;
    try {
      final file = selected.single;
      final byteLength = await file.length();
      if (byteLength == null ||
          byteLength < 1 ||
          byteLength > 3 * 1024 * 1024) {
        throw const FormatException('Invalid image size');
      }
      image = NotificationCampaignImage.validate(
        bytes: await file.readAsBytes(),
        extension: file.extension,
      );
    } on FormatException {
      if (_current) {
        setState(
          () => _error = t(
            'اختر صورة JPEG أو PNG أو WebP بحجم لا يتجاوز 3 ميجابايت.',
            'Choose a JPEG, PNG, or WebP image up to 3 MiB.',
          ),
        );
      }
      return;
    } catch (_) {
      if (_current) {
        setState(
          () => _error = t(
            'تعذر قراءة ملف الصورة.',
            'Could not read the selected image file.',
          ),
        );
      }
      return;
    }
    setState(() {
      _uploadingImage = true;
      _error = null;
    });
    try {
      final url = await _gateway.uploadImage(image);
      if (_current && url.startsWith('https://')) {
        setState(() => _image.text = url);
      } else if (_current) {
        setState(
          () => _error = t(
            'تعذر اعتماد رابط الصورة المرفوعة.',
            'The uploaded image URL could not be verified.',
          ),
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _error = t(
            'تعذر رفع الصورة. تحقق من صلاحية المالك ونوع الملف.',
            'Image upload failed. Check owner access and file type.',
          ),
        );
      }
    } finally {
      if (_current) setState(() => _uploadingImage = false);
    }
  }

  void clearEditor() {
    _selected = null;
    _title.clear();
    _body.clear();
    _titleEn.clear();
    _bodyEn.clear();
    _image.clear();
    _customerIds.clear();
    _deepLink.text = '/offers';
    _segment = 'all';
    _recurrence = 'once';
    _offerId = null;
    _branchId = null;
    _runs = [];
    _scheduled = DateTime.now().add(const Duration(hours: 1));
  }

  void select(Map<String, dynamic> row) {
    final segment = Map<String, dynamic>.from(
      row['target_segment'] as Map? ?? {},
    );
    setState(() {
      _selected = row;
      _title.text = '${row['title'] ?? ''}';
      _body.text = '${row['body'] ?? ''}';
      _titleEn.text = '${row['title_en'] ?? ''}';
      _bodyEn.text = '${row['body_en'] ?? ''}';
      _image.text = '${row['image_url'] ?? ''}';
      _deepLink.text = '${row['deep_link'] ?? '/offers'}';
      _segment = '${segment['type'] ?? 'all'}';
      _recurrence = '${row['recurrence'] ?? 'once'}';
      _offerId = row['offer_id'] as String?;
      _branchId = segment['branch_id'] as String?;
      _scheduled =
          DateTime.tryParse('${row['scheduled_at']}')?.toLocal() ??
          DateTime.now().add(const Duration(hours: 1));
      _customerIds.text = ((segment['customer_ids'] as List?) ?? []).join(', ');
      _days.text = '${segment['days'] ?? 30}';
      _points.text = '${segment['points_before_reward'] ?? 1}';
    });
    loadRuns('${row['campaign_id']}');
  }

  Map<String, dynamic> segmentValue() {
    switch (_segment) {
      case 'selected':
        final ids = _customerIds.text
            .split(RegExp(r'[,\s]+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
        if (ids.isEmpty ||
            ids.any(
              (id) => !RegExp(
                r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
              ).hasMatch(id),
            )) {
          throw const FormatException('Customer UUID list required');
        }
        return {'type': 'selected', 'customer_ids': ids};
      case 'new_customers':
      case 'inactive':
        final days = int.tryParse(_days.text.trim());
        if (days == null || days < 1 || days > 3650) {
          throw const FormatException('Days must be between 1 and 3650');
        }
        return {'type': _segment, 'days': days};
      case 'loyalty_near_reward':
        final points = int.tryParse(_points.text.trim());
        if (points == null || points < 1 || points > 1000000) {
          throw const FormatException('Points must be between 1 and 1000000');
        }
        return {'type': _segment, 'points_before_reward': points};
      case 'branch':
        final branch = _branchId;
        if (branch == null ||
            !_branches.any((row) => row['branch_id'] == branch)) {
          throw const FormatException('Active branch required');
        }
        return {'type': 'branch', 'branch_id': branch};
      default:
        return {'type': 'all'};
    }
  }

  Future<void> save({required bool schedule, bool immediate = false}) async {
    if (_busy || !_current) return;
    final title = _title.text.trim(), body = _body.text.trim();
    final link = _deepLink.text.trim();
    final image = _image.text.trim();
    if (title.isEmpty ||
        body.isEmpty ||
        title.length > 120 ||
        body.length > 1000) {
      setState(
        () => _error = t(
          'أدخل عنوانًا من 1 إلى 120 حرفًا ونصًا من 1 إلى 1000 حرف.',
          'Enter a 1–120 character title and a 1–1000 character message.',
        ),
      );
      return;
    }
    if (!RegExp(r'^/(offers|booking)(/|$)').hasMatch(link)) {
      setState(
        () => _error = t(
          'الرابط يجب أن يفتح قسم العروض أو الحجز داخل التطبيق.',
          'The link must open offers or booking inside the app.',
        ),
      );
      return;
    }
    if (image.isNotEmpty && (Uri.tryParse(image)?.scheme != 'https')) {
      setState(
        () => _error = t(
          'استخدم رابط صورة HTTPS آمنًا.',
          'Use a secure HTTPS image URL.',
        ),
      );
      return;
    }
    final oldStatus = '${_selected?['status'] ?? ''}';
    if (_selected != null &&
        !['draft', 'paused', 'scheduled'].contains(oldStatus)) {
      setState(
        () => _error = t(
          'لا يمكن تعديل محتوى حملة بدأ إرسالها.',
          'Campaign content cannot be changed after dispatch begins.',
        ),
      );
      return;
    }
    if (schedule &&
        !immediate &&
        _scheduled.isBefore(DateTime.now().add(const Duration(minutes: 5)))) {
      setState(
        () => _error = t(
          'حدد موعدًا بعد خمس دقائق على الأقل. الإرسال الفوري متوقف لحين الموافقة.',
          'Choose a time at least five minutes ahead. Immediate sending is disabled pending approval.',
        ),
      );
      return;
    }
    if (schedule && _offerId != null) {
      final linked = _offers.where((offer) => offer['offer_id'] == _offerId);
      if (linked.isEmpty ||
          linked.first['is_active'] != true ||
          linked.first['is_public'] != true) {
        setState(
          () => _error = t(
            'لا يمكن جدولة إشعار مرتبط بعرض غير نشط أو غير منشور.',
            'A campaign cannot be scheduled with an inactive or unpublished offer.',
          ),
        );
        return;
      }
    }
    Map<String, dynamic> target;
    try {
      target = segmentValue();
    } catch (_) {
      setState(
        () => _error = t(
          'بيانات الشريحة غير صالحة.',
          'The audience segment is invalid.',
        ),
      );
      return;
    }
    final actor = _gateway.actorId;
    if (actor == null) return;
    final effectiveScheduled = immediate ? DateTime.now() : _scheduled;
    final payload = <String, dynamic>{
      'title': title,
      'body': body,
      'title_en': _titleEn.text.trim().isEmpty ? null : _titleEn.text.trim(),
      'body_en': _bodyEn.text.trim().isEmpty ? null : _bodyEn.text.trim(),
      'image_url': image.isEmpty ? null : image,
      'deep_link': link,
      'offer_id': _offerId,
      'target_segment': target,
      'scheduled_at': effectiveScheduled.toUtc().toIso8601String(),
      'next_scheduled_at': effectiveScheduled.toUtc().toIso8601String(),
      'time_zone': 'Africa/Cairo',
      'recurrence': _recurrence,
      'status': schedule ? 'scheduled' : 'draft',
      'updated_by': actor,
    };
    if (_recurrence == 'once') payload['recurrence_ends_at'] = null;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_selected == null) {
        payload['campaign_id'] = newOrderRequestId();
        payload['created_by'] = actor;
        await _gateway.insertCampaign(payload);
      } else {
        await _gateway.updateCampaign('${_selected!['campaign_id']}', payload);
      }
      if (!_current || generation != _generation) return;
      clearEditor();
      await load();
    } catch (_) {
      if (_current && generation == _generation) {
        setState(
          () => _error = t(
            'لم نتأكد من الحفظ. لم يتم استدعاء خدمة إرسال الإشعارات.',
            'Save was not confirmed. No notification dispatcher was called.',
          ),
        );
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> setStatus(String status) async {
    final row = _selected;
    if (row == null || _busy || !_current) return;
    if (!['paused', 'cancelled'].contains(status) ||
        !['draft', 'scheduled', 'paused'].contains(row['status'])) {
      return;
    }
    final actor = _gateway.actorId;
    if (actor == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _gateway.updateCampaign('${row['campaign_id']}', {
        'status': status,
        'updated_by': actor,
      });
      if (!_current || generation != _generation) return;
      await load();
    } catch (_) {
      if (_current && generation == _generation) {
        setState(
          () => _error = t(
            'تعذر تحديث حالة الإشعار.',
            'Notification status could not be updated.',
          ),
        );
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  String localDate(dynamic value) {
    final date = DateTime.tryParse('$value')?.toLocal();
    if (date == null) return '—';
    final digits =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return digits;
  }

  Widget field(
    TextEditingController controller,
    String ar,
    String en, {
    int maxLines = 1,
    int? maxLength,
    String? hint,
  }) => TextField(
    controller: controller,
    maxLines: maxLines,
    maxLength: maxLength,
    decoration: InputDecoration(labelText: t(ar, en), hintText: hint),
  );

  Widget buildEditor() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('إنشاء أو تعديل إشعار', 'Create or edit notification'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_busy) const LinearProgressIndicator(),
          field(_title, 'العنوان بالعربية', 'Arabic title', maxLength: 120),
          field(
            _body,
            'النص بالعربية',
            'Arabic message',
            maxLines: 3,
            maxLength: 1000,
          ),
          field(
            _titleEn,
            'العنوان بالإنجليزية',
            'English title',
            maxLength: 120,
          ),
          field(
            _bodyEn,
            'النص بالإنجليزية',
            'English message',
            maxLines: 3,
            maxLength: 1000,
          ),
          field(
            _image,
            'رابط الصورة HTTPS (اختياري)',
            'HTTPS image URL (optional)',
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('campaign-upload-image'),
              onPressed: _busy || _uploadingImage ? null : uploadCampaignImage,
              icon: _uploadingImage
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_outlined),
              label: Text(
                t(
                  'رفع صورة ترويجية آمنة (حتى 3 ميجابايت)',
                  'Upload campaign image (up to 3 MiB)',
                ),
              ),
            ),
          ),
          field(
            _deepLink,
            'وجهة الإشعار',
            'Notification destination',
            hint: '/offers or /booking',
          ),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: _offerId,
            decoration: InputDecoration(
              labelText: t(
                'العرض المرتبط (اختياري)',
                'Linked offer (optional)',
              ),
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(t('بدون عرض مرتبط', 'No linked offer')),
              ),
              for (final offer in _offers)
                DropdownMenuItem<String?>(
                  value: '${offer['offer_id']}',
                  child: Text(
                    '${offer['name']} · ${offer['offer_type']}${offer['is_active'] == true && offer['is_public'] == true ? '' : ' · ${t('غير منشور', 'unpublished')}'}',
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _offerId = value),
          ),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _segment,
            decoration: InputDecoration(
              labelText: t('الشريحة', 'Audience segment'),
            ),
            items: [
              DropdownMenuItem(
                value: 'all',
                child: Text(
                  t(
                    'كل الموافقين على التسويق',
                    'All marketing-consented customers',
                  ),
                ),
              ),
              DropdownMenuItem(
                value: 'branch',
                child: Text(t('عملاء فرع محدد', 'Customers of one branch')),
              ),
              DropdownMenuItem(
                value: 'selected',
                child: Text(
                  t('عملاء محددون بالمعرّف', 'Selected customers by ID'),
                ),
              ),
              DropdownMenuItem(
                value: 'new_customers',
                child: Text(t('عملاء جدد', 'New customers')),
              ),
              DropdownMenuItem(
                value: 'inactive',
                child: Text(t('عملاء غير نشطين', 'Inactive customers')),
              ),
              DropdownMenuItem(
                value: 'loyalty_near_reward',
                child: Text(
                  t('قريبون من مكافأة ولاء', 'Near a loyalty reward'),
                ),
              ),
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() => _segment = v ?? 'all'),
          ),
          if (_segment == 'branch')
            DropdownButtonFormField<String?>(
              key: const ValueKey('campaign-branch-target'),
              isExpanded: true,
              initialValue: _branchId,
              decoration: InputDecoration(labelText: t('الفرع', 'Branch')),
              items: [
                for (final branch in _branches)
                  DropdownMenuItem<String?>(
                    value: '${branch['branch_id']}',
                    child: Text(
                      '${_ar ? branch['name_ar'] : (branch['name_en'] ?? branch['name_ar'])}',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _branchId = value),
            ),
          if (_segment == 'selected')
            field(
              _customerIds,
              'معرّفات العملاء UUID فقط',
              'Customer UUIDs only',
              hint: 'ID, ID',
            ),
          if (_segment == 'new_customers' || _segment == 'inactive')
            field(_days, 'عدد الأيام', 'Days'),
          if (_segment == 'loyalty_near_reward')
            field(
              _points,
              'عدد النقاط المتبقية للمكافأة',
              'Points before reward',
            ),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _recurrence,
            decoration: InputDecoration(labelText: t('التكرار', 'Recurrence')),
            items: [
              DropdownMenuItem(
                value: 'once',
                child: Text(t('مرة واحدة', 'Once')),
              ),
              DropdownMenuItem(
                value: 'daily',
                child: Text(t('يوميًا', 'Daily')),
              ),
              DropdownMenuItem(
                value: 'weekly',
                child: Text(t('أسبوعيًا', 'Weekly')),
              ),
              DropdownMenuItem(
                value: 'monthly',
                child: Text(t('شهريًا', 'Monthly')),
              ),
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() => _recurrence = v ?? 'once'),
          ),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _scheduled,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (date == null || !mounted) return;
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(_scheduled),
                    );
                    if (time != null && mounted) {
                      setState(
                        () => _scheduled = DateTime(
                          date.year,
                          date.month,
                          date.day,
                          time.hour,
                          time.minute,
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.schedule),
            label: Text(
              '${t('موعد الإرسال', 'Scheduled for')}: ${localDate(_scheduled.toUtc())}',
            ),
          ),
          if (_image.text.trim().isNotEmpty &&
              Uri.tryParse(_image.text.trim())?.scheme == 'https')
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                _image.text.trim(),
                height: 160,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Text(
                  t('تعذر معاينة الصورة.', 'Image preview unavailable.'),
                ),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xff071a36),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _ar
                      ? (_title.text.isEmpty ? 'معاينة الإشعار' : _title.text)
                      : (_titleEn.text.isEmpty
                            ? (_title.text.isEmpty
                                  ? 'Notification preview'
                                  : _title.text)
                            : _titleEn.text),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _ar
                      ? (_body.text.isEmpty ? 'سيظهر النص هنا' : _body.text)
                      : (_bodyEn.text.isEmpty
                            ? (_body.text.isEmpty
                                  ? 'Message preview'
                                  : _body.text)
                            : _bodyEn.text),
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const ValueKey('campaign-save-draft'),
                onPressed: _busy ? null : () => save(schedule: false),
                child: Text(t('حفظ كمسودة', 'Save draft')),
              ),
              FilledButton(
                key: const ValueKey('campaign-schedule'),
                onPressed: _busy ? null : () => save(schedule: true),
                child: Text(t('جدولة الإشعار', 'Schedule notification')),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('campaign-send-now'),
                onPressed: _busy
                    ? null
                    : () => save(schedule: true, immediate: true),
                icon: const Icon(Icons.send_outlined),
                label: Text(t('إرسال فورًا', 'Send now')),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => setState(clearEditor),
                child: Text(t('إشعار جديد', 'New notification')),
              ),
            ],
          ),
          Text(
            t(
              'زر الإرسال الفوري يضع الحملة في قائمة التنفيذ الآن؛ بوابات التوصيل الخارجية والداخلية مغلقة على QA حتى الموافقة.',
              'Send now queues the campaign for execution. External and in-app delivery gates remain closed on QA until approved.',
            ),
            style: const TextStyle(color: Color(0xff174b83)),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final canStatus =
        _selected != null &&
        ['draft', 'scheduled', 'paused'].contains(_selected!['status']);
    return Scaffold(
      appBar: AppBar(
        title: Text(t('إدارة إشعارات العملاء', 'Customer Notifications')),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              t(
                'تُحترم موافقة العميل التسويقية في الإرسال. السجل داخل التطبيق مستقل عن Push.',
                'Marketing consent is enforced by the dispatcher. In-app history remains separate from push.',
              ),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_busy) const LinearProgressIndicator(),
            buildEditor(),
            const SizedBox(height: 16),
            Text(
              t('الحملات والإشعارات', 'Campaigns and notifications'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (_rows.isEmpty && !_busy)
              Text(t('لا توجد حملات محفوظة.', 'No saved campaigns.')),
            for (final row in _rows)
              Card(
                child: ListTile(
                  selected: _selected?['campaign_id'] == row['campaign_id'],
                  title: Text('${row['title'] ?? ''}'),
                  subtitle: Text(
                    '${row['status'] ?? 'draft'} · ${localDate(row['scheduled_at'])}',
                  ),
                  onTap: _busy ? null : () => select(row),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            if (_selected != null) ...[
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy || !canStatus
                        ? null
                        : () => setStatus('paused'),
                    child: Text(t('إيقاف مؤقت', 'Pause')),
                  ),
                  OutlinedButton(
                    onPressed: _busy || !canStatus
                        ? null
                        : () => setStatus('cancelled'),
                    child: Text(t('إلغاء الجدولة', 'Cancel schedule')),
                  ),
                ],
              ),
              Text(
                t('سجل التشغيل', 'Run history'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_runs.isEmpty)
                Text(
                  t(
                    'لا توجد عمليات إرسال مسجلة.',
                    'No dispatch runs recorded.',
                  ),
                ),
              for (final run in _runs)
                ListTile(
                  dense: true,
                  leading: Icon(
                    run['status'] == 'failed'
                        ? Icons.error_outline
                        : Icons.notifications_outlined,
                  ),
                  title: Text(
                    '${run['status']} · ${localDate(run['scheduled_for'])}',
                  ),
                  subtitle: Text(
                    '${t('المستلمون', 'Recipients')}: ${run['recipient_count'] ?? 0} · ${t('مقبول من FCM', 'FCM accepted')}: ${run['accepted_count'] ?? 0} · ${t('داخل التطبيق', 'In-app')}: ${run['in_app_count'] ?? 0} · ${t('فشل Push', 'Push failed')}: ${run['failed_count'] ?? 0}',
                    // Push provider acceptance and in-app delivery are separate
                    // facts; neither is presented as a device-open count.
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
