import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DocumentAssistantScreen extends StatefulWidget {
  final SupabaseClient client;
  const DocumentAssistantScreen({super.key, required this.client});
  @override
  State<DocumentAssistantScreen> createState() =>
      _DocumentAssistantScreenState();
}

class _DocumentAssistantScreenState extends State<DocumentAssistantScreen> {
  final _question = TextEditingController();
  bool _consent = false;
  bool _busy = false;
  Map<String, dynamic>? _result;
  String? _error;
  String _t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    if (_busy || !_consent || _question.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final response = await widget.client.functions.invoke(
        'ask-business-documents',
        body: {'question': _question.text.trim(), 'consent': true},
      );
      if (mounted) {
        setState(() => _result = Map<String, dynamic>.from(response.data as Map));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _t(
            'تعذر الحصول على إجابة. تحقق من اتصالك وإعداد خدمة AI وصلاحية المالك.',
            'Could not answer. Check connection, AI setup and owner access.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_t('مساعد مستندات المنشأة', 'Business document assistant')),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          _t(
            'يساعدك باستخدام بيانات المستندات المعتمدة ويذكر المصادر. راجع المستند الأصلي قبل اتخاذ قرار.',
            'Uses approved document fields and cites its sources. Review the original document before making a decision.',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _question,
          maxLength: 1000,
          maxLines: 3,
          onChanged: (_) {
            if (_result != null) setState(() => _result = null);
          },
          decoration: InputDecoration(labelText: _t('سؤالك', 'Your question')),
        ),
        CheckboxListTile(
          value: _consent,
          onChanged: _busy
              ? null
              : (value) => setState(() => _consent = value == true),
          title: Text(
            _t(
              'أوافق على إرسال السؤال وحقول المستندات المعتمدة إلى مزود AI.',
              'I agree to send this question and approved document fields to the AI provider.',
            ),
          ),
        ),
        FilledButton(
          onPressed: _consent && !_busy ? _ask : null,
          child: Text(
            _busy
                ? _t('جارٍ البحث...', 'Searching...')
                : _t('اسأل المساعد', 'Ask assistant'),
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        if (_result != null) ...[
          const SizedBox(height: 20),
          SelectableText('${_result!['answer']}'),
          const SizedBox(height: 12),
          ...((_result!['citations'] as List? ?? []).cast<Map>()).map(
            (citation) => ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text('${citation['title']}'),
            ),
          ),
        ],
      ],
    ),
  );
}
