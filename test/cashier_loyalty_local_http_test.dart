// Explicit isolated loopback QA only. Skipped without private local session defines.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';
import 'package:sabiha_hub/cashier_loyalty_intent.dart';

class LocalQaTransport extends http.BaseClient {
  final inner = http.Client();
  final methods = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (uri.host != '127.0.0.1' ||
        uri.port != 54391 ||
        request.method != 'POST' ||
        !const {
          '/rest/v1/rpc/seal_cashier_loyalty_draft',
          '/rest/v1/rpc/get_cashier_loyalty_draft_intent',
        }.contains(uri.path)) {
      throw StateError(
        'QA transport refused a non-seal or non-loopback request',
      );
    }
    methods.add(uri.path.split('/').last);
    final next =
        http.Request(
            request.method,
            uri.replace(path: uri.path.replaceFirst('/rest/v1', '')),
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = await request.finalize().toBytes();
    return inner.send(next);
  }

  @override
  void close() => inner.close();
}

void main() {
  const owner = String.fromEnvironment('QA_MIXED_LOYALTY_OWNER_SESSION');
  const customer = String.fromEnvironment('QA_MIXED_LOYALTY_CUSTOMER_SESSION');
  const branch = String.fromEnvironment('QA_MIXED_LOYALTY_BRANCH');
  const draft = String.fromEnvironment('QA_MIXED_LOYALTY_DRAFT');
  test(
    'Real SDK adapter seals a QA mixed draft then invalidates on account change',
    () async {
      final transport = LocalQaTransport();
      final client = SupabaseClient(
        'http://127.0.0.1:54391',
        'isolated-qa-public-client',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: transport,
      );
      await client.auth.recoverSession(owner);
      final gateway = SupabaseCashierCartGateway(client);
      final seal = CashierLoyaltyDraftSeal(
        gateway: gateway,
        branch: branch,
        draft: draft,
        draftVersion: 1,
        bindingVersion: 1,
      );
      try {
        final receipt = await seal.prepare();
        expect(receipt['seal_only'], true);
        expect(receipt['consent_authorized'], false);
        expect(await seal.prepare(), receipt);
        final view = await seal.refresh();
        expect(view['state'], 'current');
        expect(view['wallet_disclosed'], false);
        expect(transport.methods, [
          'seal_cashier_loyalty_draft',
          'seal_cashier_loyalty_draft',
          'get_cashier_loyalty_draft_intent',
        ]);
        await client.auth.recoverSession(customer);
        await Future<void>.delayed(Duration.zero);
        expect(gateway.current, false);
        expect(() => seal.prepare(), throwsStateError);
        expect(transport.methods.length, 3);
      } finally {
        seal.dispose();
        await client.dispose();
        transport.close();
      }
    },
    skip: owner.isEmpty ? 'Requires isolated QA local session defines' : false,
  );
}
