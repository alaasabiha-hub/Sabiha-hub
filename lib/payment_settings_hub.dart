import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'payment_finance.dart';

class FinancialSettingsScreen extends StatelessWidget {
  final SupabaseClient client;
  const FinancialSettingsScreen({super.key, required this.client});
  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Scaffold(
      appBar: AppBar(
        title: Text(ar ? 'الإعدادات المالية' : 'Financial settings'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.payments_outlined),
            title: Text(ar ? 'سياسة الدفع والعمولات' : 'Payment policy & fees'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PaymentPolicyScreen(client: client),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: Text(
              ar ? 'التحليل الذكي للمدفوعات' : 'AI Payment Analytics',
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AiPaymentAnalyticsScreen(client: client),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
