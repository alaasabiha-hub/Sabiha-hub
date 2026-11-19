import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/catalog_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Existing car photo is resized and re-encoded as bounded PNG', () async {
    final original = await File('assets/customer/reference-wash.jpg')
        .readAsBytes();
    final result = await prepareCatalogImage(original);
    expect(result.length, lessThanOrEqualTo(2097152));
    expect(result.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await ui.instantiateImageCodec(result);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, lessThanOrEqualTo(1024));
    expect(frame.image.height, lessThanOrEqualTo(1024));
    frame.image.dispose();
    codec.dispose();
  });
  test(
    'Rejects SVG, oversized payloads and forged PNG before upload',
    () async {
      await expectLater(
        prepareCatalogImage(Uint8List.fromList('<svg></svg>'.codeUnits)),
        throwsFormatException,
      );
      await expectLater(
        prepareCatalogImage(Uint8List(8388609)),
        throwsFormatException,
      );
      await expectLater(
        prepareCatalogImage(
          Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0, 1]),
        ),
        throwsA(anything),
      );
    },
  );
}
