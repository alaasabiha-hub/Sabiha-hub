import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cashier_invoice_draft.dart';

/// Uses the centre's existing default branch without exposing a branch selector.
class CashierPointOfSaleEntry extends StatefulWidget {
  const CashierPointOfSaleEntry({super.key, required this.client});
  final SupabaseClient client;
  @override
  State<CashierPointOfSaleEntry> createState() =>
      _CashierPointOfSaleEntryState();
}

class _CashierPointOfSaleEntryState extends State<CashierPointOfSaleEntry> {
  late final gateway = SupabaseCashierCartGateway(widget.client);
  late final Future<String> branch = resolveBranch();
  bool replaced = false;
  Future<String> resolveBranch() async {
    if (!gateway.current || replaced) {
      throw StateError('Cashier session unavailable');
    }
    final value = await gateway.client
        .rpc('default_branch_id')
        .timeout(const Duration(seconds: 20));
    if (!gateway.current || replaced || value is! String || value.isEmpty) {
      throw StateError('Centre unavailable');
    }
    return value;
  }

  @override
  void didUpdateWidget(covariant CashierPointOfSaleEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) replaced = true;
  }

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return StreamBuilder<void>(
      stream: gateway.changes,
      builder: (context, _) => FutureBuilder<String>(
        future: branch,
        builder: (context, snapshot) {
          if (!replaced && gateway.current && snapshot.hasData) {
            return CashierInvoiceDraftScreen(
              gateway: gateway,
              branch: snapshot.data!,
            );
          }
          return Scaffold(
            appBar: AppBar(title: Text(ar ? 'نقطة البيع' : 'Point of sale')),
            body: Center(
              child: replaced || !gateway.current
                  ? Text(
                      ar
                          ? 'أعد تسجيل الدخول لفتح الكاشير.'
                          : 'Sign in again to open the cashier.',
                    )
                  : snapshot.hasError
                  ? Text(
                      ar ? 'تعذر فتح الكاشير. تحقق من صلاحية المركز والاتصال.' : 'Unable to open the cashier. Check centre access and connection.',
                    )
                  : const CircularProgressIndicator(),
            ),
          );
        },
      ),
    );
  }
}
