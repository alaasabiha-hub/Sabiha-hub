import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StaffProfileSnapshot {
  const StaffProfileSnapshot({required this.fullName, this.avatarUrl});
  final String fullName;
  final String? avatarUrl;
}

String _profileText(BuildContext context, String ar, String en) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

class StaffProfileEditorScreen extends StatefulWidget {
  const StaffProfileEditorScreen({
    super.key,
    required this.client,
    this.onSaved,
  });

  final SupabaseClient client;
  final ValueChanged<StaffProfileSnapshot>? onSaved;

  @override
  State<StaffProfileEditorScreen> createState() =>
      _StaffProfileEditorScreenState();
}

class _StaffProfileEditorScreenState extends State<StaffProfileEditorScreen> {
  final _name = TextEditingController();
  final _picker = ImagePicker();
  Uint8List? _selectedBytes;
  String? _avatarPath, _avatarUrl, _selectedExtension, _selectedMime;
  bool _loading = true, _saving = false, _clearAvatar = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final userId = widget.client.auth.currentUser?.id;
      if (userId == null) throw StateError('Authentication required');
      final result = await widget.client.rpc('get_my_staff_profile');
      if (!mounted || widget.client.auth.currentUser?.id != userId) return;
      final data = Map<String, dynamic>.from(result as Map);
      _name.text = data['full_name']?.toString() ?? '';
      _avatarPath = data['avatar_path']?.toString();
      if (_avatarPath != null && _avatarPath!.isNotEmpty) {
        _avatarUrl = await widget.client.storage
            .from('staff-profile-avatars')
            .createSignedUrl(_avatarPath!, 3600);
        if (!mounted || widget.client.auth.currentUser?.id != userId) return;
      }
    } catch (_) {
      if (mounted) {
        _message(
          _profileText(
            context,
            'تعذر تحميل الملف الشخصي. تحقق من اتصالك وصلاحية الحساب.',
            'Could not load your profile. Check the connection and account access.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _choose(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 86,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty || bytes.length > 3 * 1024 * 1024) {
        _message(
          _profileText(
            context,
            'اختر صورة لا تتجاوز 3 ميجابايت.',
            'Choose an image no larger than 3 MB.',
          ),
        );
        return;
      }
      var ext = picked.name.split('.').last.toLowerCase();
      var mime = picked.mimeType?.toLowerCase();
      if (mime == 'image/jpg') mime = 'image/jpeg';
      if (mime == null ||
          !const {'image/jpeg', 'image/png', 'image/webp'}.contains(mime)) {
        mime = switch (ext) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => null,
        };
      }
      if (mime == null) {
        _message(
          _profileText(
            context,
            'الصيغ المدعومة: JPEG وPNG وWebP.',
            'Supported formats: JPEG, PNG and WebP.',
          ),
        );
        return;
      }
      ext = switch (mime) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        _ => 'webp',
      };
      setState(() {
        _selectedBytes = bytes;
        _selectedExtension = ext;
        _selectedMime = mime;
        _clearAvatar = false;
      });
    } catch (_) {
      _message(
        _profileText(
          context,
          'تعذر فتح الصورة. تحقق من إذن الكاميرا أو المعرض.',
          'Could not open the image. Check camera or photo-library permission.',
        ),
      );
    }
  }

  Future<void> _save() async {
    final user = widget.client.auth.currentUser;
    final name = _name.text.trim();
    if (user == null) {
      _message(
        _profileText(
          context,
          'انتهت الجلسة. سجّل الدخول مجددًا.',
          'Your session ended. Please sign in again.',
        ),
      );
      return;
    }
    if (name.length < 2 || name.length > 100) {
      _message(
        _profileText(
          context,
          'اكتب اسمًا من حرفين إلى 100 حرف.',
          'Enter a name between 2 and 100 characters.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    String? uploadedPath;
    final oldPath = _avatarPath;
    try {
      String? nextPath = _clearAvatar ? null : _avatarPath;
      if (_selectedBytes != null) {
        if (widget.client.auth.currentUser?.id != user.id) {
          throw StateError('The signed-in account changed.');
        }
        final path = '${user.id}/${_uuidV4()}.$_selectedExtension';
        uploadedPath = path;
        await widget.client.storage
            .from('staff-profile-avatars')
            .uploadBinary(
              path,
              _selectedBytes!,
              fileOptions: FileOptions(
                contentType: _selectedMime!,
                upsert: false,
              ),
            );
        nextPath = uploadedPath;
      }
      if (widget.client.auth.currentUser?.id != user.id) {
        throw StateError('The signed-in account changed.');
      }
      String? signedUrl;
      if (nextPath != null) {
        signedUrl = await widget.client.storage
            .from('staff-profile-avatars')
            .createSignedUrl(nextPath, 3600);
      }
      if (widget.client.auth.currentUser?.id != user.id) {
        throw StateError('The signed-in account changed.');
      }
      await widget.client.rpc(
        'save_my_staff_profile',
        params: {'p_full_name': name, 'p_avatar_path': nextPath},
      );
      if (widget.client.auth.currentUser?.id != user.id) {
        throw StateError('The signed-in account changed.');
      }
      try {
        await widget.client.auth.updateUser(
          UserAttributes(data: {...?user.userMetadata, 'full_name': name}),
        );
      } catch (_) {
        // staff_profiles is canonical; auth metadata is only a display cache.
      }
      if (oldPath != null &&
          oldPath != nextPath &&
          widget.client.auth.currentUser?.id == user.id) {
        try {
          await widget.client.storage.from('staff-profile-avatars').remove([
            oldPath,
          ]);
        } catch (_) {
          // Pointer is already cleared/replaced; an orphan can be cleaned later.
        }
      }
      if (!mounted) return;
      setState(() {
        _avatarPath = nextPath;
        _avatarUrl = signedUrl;
        _selectedBytes = null;
        _clearAvatar = false;
      });
      widget.onSaved?.call(
        StaffProfileSnapshot(fullName: name, avatarUrl: signedUrl),
      );
      _message(_profileText(context, 'تم حفظ الملف الشخصي.', 'Profile saved.'));
    } catch (_) {
      if (uploadedPath != null &&
          widget.client.auth.currentUser?.id == user.id) {
        try {
          await widget.client.storage.from('staff-profile-avatars').remove([
            uploadedPath,
          ]);
        } catch (_) {}
      }
      if (!mounted) return;
      _message(
        _profileText(
          context,
          'تعذر حفظ الملف الشخصي. تحقق من اتصالك والصلاحيات ثم حاول مجددًا.',
          'Could not save your profile. Check connection and access, then try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider<Object>? image = _selectedBytes != null
        ? MemoryImage(_selectedBytes!)
        : (!_clearAvatar && _avatarUrl != null
              ? NetworkImage(_avatarUrl!)
              : null);
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    return Scaffold(
      backgroundColor: const Color(0xfff4f6fa),
      appBar: AppBar(
        title: Text(_profileText(context, 'ملفي الشخصي', 'My profile')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 54,
                            backgroundColor: const Color(0xffdce7f5),
                            foregroundImage: image,
                            child: image == null
                                ? const Icon(
                                    Icons.person_outline,
                                    size: 58,
                                    color: Color(0xff174b83),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            widget.client.auth.currentUser?.email ?? '',
                            textDirection: TextDirection.ltr,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _saving
                                    ? null
                                    : () => _choose(ImageSource.gallery),
                                icon: const Icon(Icons.photo_library_outlined),
                                label: Text(
                                  _profileText(
                                    context,
                                    'اختيار صورة',
                                    'Choose photo',
                                  ),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: _saving
                                    ? null
                                    : () => _choose(ImageSource.camera),
                                icon: const Icon(Icons.camera_alt_outlined),
                                label: Text(
                                  _profileText(
                                    context,
                                    'التقاط صورة',
                                    'Take photo',
                                  ),
                                ),
                              ),
                              if (_avatarPath != null || _selectedBytes != null)
                                TextButton.icon(
                                  onPressed: _saving
                                      ? null
                                      : () => setState(() {
                                          _selectedBytes = null;
                                          _selectedExtension = null;
                                          _selectedMime = null;
                                          _clearAvatar = true;
                                        }),
                                  icon: const Icon(Icons.delete_outline),
                                  label: Text(
                                    _profileText(
                                      context,
                                      'إزالة الصورة',
                                      'Remove photo',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          Text(
                            _profileText(
                              context,
                              'JPEG أو PNG أو WebP، بحد أقصى 3 ميجابايت.',
                              'JPEG, PNG or WebP, up to 3 MB.',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _name,
                    textDirection: isArabic
                        ? TextDirection.rtl
                        : TextDirection.ltr,
                    textCapitalization: TextCapitalization.words,
                    maxLength: 100,
                    decoration: InputDecoration(
                      labelText: _profileText(
                        context,
                        'الاسم الظاهر',
                        'Display name',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      _saving
                          ? _profileText(context, 'جارٍ الحفظ...', 'Saving...')
                          : _profileText(
                              context,
                              'حفظ التعديلات',
                              'Save changes',
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
