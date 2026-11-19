import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/catalog_media.dart';

String session(String id) => jsonEncode({
  'access_token': 'unit-session-$id',
  'refresh_token': 'unit-refresh-$id',
  'token_type': 'bearer',
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  'user': {
    'id': id,
    'aud': 'authenticated',
    'app_metadata': {},
    'user_metadata': {},
    'created_at': '2026-11-16T00:00:00Z',
  },
});

void main() {
  for (final duringSigning in [false, true]) {
    test(
      'Session change clears all display capabilities ${duringSigning ? 'during failed signing' : 'between RPC pages'}',
      () async {
        late SupabaseClient client;
        var pages = 0;
        client = SupabaseClient(
          'http://127.0.0.1:9999',
          'unit-key',
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (request.url.path.endsWith('/rpc/get_catalog_image_paths')) {
              pages++;
              if (!duringSigning && pages == 2) {
                await client.auth.recoverSession(session('customer-b'));
              }
              final batch = List<String>.from(body['p_items']);
              return http.Response(
                jsonEncode({
                  'images': [
                    {
                      'item_id': batch.first,
                      'path': '${batch.first}.png',
                      'version': 1,
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            }
            if (duringSigning) {
              await client.auth.recoverSession(session('customer-b'));
              throw StateError('Interrupted signing after session change');
            }
            final path = (body['paths'] as List).first;
            return http.Response(
              jsonEncode([
                {
                  'path': path,
                  'signedURL':
                      '/object/sign/catalog-images/$path?token=unit-only',
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        await client.auth.recoverSession(session('customer-a'));
        final rows = List.generate(
          205,
          (i) => <String, dynamic>{
            'item_id': 'item-$i',
            'image_display_url': 'stale-unit-capability',
          },
        );
        await enrichCatalogImages(client, rows);
        expect(client.auth.currentUser?.id, 'customer-b');
        expect(
          rows.every(
            (r) =>
                r['image_display_url'] == null &&
                r['image_path'] == null &&
                r['image_version'] == null,
          ),
          isTrue,
        );
        expect(pages, duringSigning ? 1 : 2);
        await client.dispose();
      },
    );
  }
}
