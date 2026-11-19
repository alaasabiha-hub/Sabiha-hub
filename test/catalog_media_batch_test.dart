import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/catalog_media.dart';

void main() {
  test('205 catalogue rows use bounded RPC pages and batch signing with per-file fallback', () async {
    var pages = 0, signs = 0;
    var hideImages = false;
    final ids = <String>[];
    final client = SupabaseClient(
      'http://127.0.0.1:9999',
      'local-unit-key',
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/rpc/get_catalog_image_paths')) {
          pages++;
          final batch = List<String>.from(body['p_items']);
          expect(batch.length, lessThanOrEqualTo(100));
          ids.addAll(batch);
          return http.Response(
            jsonEncode({
              'images': hideImages
                  ? []
                  : [
                      {
                        'item_id': batch.first,
                        'version': 1,
                        'path': '${batch.first}.png',
                      },
                      {
                        'item_id': batch[1],
                        'version': 1,
                        'path': 'missing-${batch[1]}.png',
                      },
                    ],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        expect(request.url.path, '/storage/v1/object/sign/catalog-images');
        signs++;
        final paths = List<String>.from(body['paths']);
        return http.Response(
          jsonEncode([
            {
              'path': paths[0],
              'signedURL':
                  '/object/sign/catalog-images/${paths[0]}?token=unit-only',
            },
            {'path': paths[1], 'error': 'not found'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    final rows = List.generate(
      205,
      (i) => <String, dynamic>{
        'item_id': 'item-$i',
        'image_url': 'https://example.invalid/original.png',
      },
    );
    await enrichCatalogImages(client, rows);
    expect(pages, 3);
    expect(signs, 3);
    expect(ids.toSet().length, 205);
    expect(rows[0]['image_display_url'], contains('item-0.png'));
    expect(rows[1]['image_display_url'], isNull);
    expect(rows[1]['image_version'], 1);
    expect(rows[1]['image_url'], 'https://example.invalid/original.png');
    await enrichCatalogImages(client, rows);
    expect(pages, 6); // Permission is rechecked on every refresh.
    expect(
      signs,
      3,
    ); // Same scoped paths reuse unexpired positive/negative results.
    hideImages = true;
    await enrichCatalogImages(client, rows);
    expect(pages, 9);
    expect(signs, 3);
    expect(
      rows[0]['image_display_url'],
      isNull,
    ); // Cached capability is not reattached after access denial.
    await client.dispose();
  });
}
