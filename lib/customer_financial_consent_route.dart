import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_reward_financial_consent.dart';

/// Discovers only the authenticated customer's proposal through the existing
/// gateway. No route argument supplies a customer, price or reward authority.
class CustomerFinancialConsentLink extends StatelessWidget {
  const CustomerFinancialConsentLink({
    super.key,
    required this.client,
    this.gateway,
    this.store,
  });
  final SupabaseClient client;
  final OfflineFinancialGateway? gateway;
  final OfflineFinancialStore? store;

  String t(BuildContext context, String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const ValueKey('customer-financial-consent-link'),
      leading: const Icon(Icons.fact_check_outlined),
      title: Text(
        t(context, 'موافقات مكافآت الزيارات', 'Visit reward consents'),
      ),
      subtitle: Text(
        t(
          context,
          'مراجعة الشروط والموافقة المالية أو سحبها',
          'Review terms and financial consent or withdraw it',
        ),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(
              title: Text(
                t(context, 'موافقات مكافآت الزيارات', 'Visit reward consents'),
              ),
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: OfflineRewardFinancialConsentPanel(
                    client: client,
                    gateway: gateway,
                    store: store,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
