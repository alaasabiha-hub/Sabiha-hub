import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

/// Decode, bound and re-encode: no original metadata, SVG or animated payload
/// is uploaded. Full-size decode is avoided until dimensions are checked.
Future<Uint8List> prepareCatalogImage(Uint8List bytes) async {
  if (bytes.length > 8 * 1024 * 1024 || bytes.length < 8) {
    throw const FormatException('Image size limit');
  }
  final png =
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10;
  final jpeg = bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255;
  if (!png && !jpeg) throw const FormatException('JPEG or PNG required');
  final (width, height) = catalogImageDimensions(bytes, png: png);
  if (width < 1 ||
      height < 1 ||
      width > 8000 ||
      height > 8000 ||
      width * height > 16000000) {
    throw const FormatException('Image dimensions limit');
  }
  for (final limit in [1024, 768, 512]) {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: width >= height ? (width > limit ? limit : width) : null,
      targetHeight: height > width ? (height > limit ? limit : height) : null,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data != null && data.lengthInBytes <= 2 * 1024 * 1024) {
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
  throw const FormatException('Compressed image size limit');
}

/// Read bounded dimensions before allocating a decoded raster. ImageDescriptor
/// dimension getters are unsupported on Flutter Web; no full-size probe decode.
(int, int) catalogImageDimensions(Uint8List bytes, {required bool png}) {
  if (png) {
    if (bytes.length < 33 ||
        bytes[12] != 73 ||
        bytes[13] != 72 ||
        bytes[14] != 68 ||
        bytes[15] != 82) {
      throw const FormatException('PNG header required');
    }
    final data = ByteData.sublistView(bytes);
    return (data.getUint32(16), data.getUint32(20));
  }
  var offset = 2;
  const sof = {
    0xc0,
    0xc1,
    0xc2,
    0xc3,
    0xc5,
    0xc6,
    0xc7,
    0xc9,
    0xca,
    0xcb,
    0xcd,
    0xce,
    0xcf,
  };
  for (
    var segments = 0;
    segments < 2048 && offset + 3 < bytes.length;
    segments++
  ) {
    if (bytes[offset++] != 255) {
      throw const FormatException('JPEG marker required');
    }
    while (offset < bytes.length && bytes[offset] == 255) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xda || marker == 0xd9) break;
    if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
    if (offset + 1 >= bytes.length) break;
    final length = bytes[offset] * 256 + bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    if (sof.contains(marker)) {
      if (length < 8) break;
      return (
        bytes[offset + 5] * 256 + bytes[offset + 6],
        bytes[offset + 3] * 256 + bytes[offset + 4],
      );
    }
    offset += length;
  }
  throw const FormatException('JPEG dimensions required');
}

abstract class OwnerCatalogMedia {
  Future<String?> uploadImage(String branch, String item);
}

Future<String?> pickAndUploadCatalogImage(
  SupabaseClient client,
  String branch,
  String item,
  bool Function() current,
) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['jpg', 'jpeg', 'png'],
  );
  if (file == null) return null;
  final size = await file.length();
  if (size == null || size > 8 * 1024 * 1024) {
    throw const FormatException('Image size limit');
  }
  final bytes = await prepareCatalogImage(await file.readAsBytes());
  if (!current()) throw StateError('Session changed');
  final path = '$branch/$item/${newOrderRequestId()}.png';
  await client.storage
      .from('catalog-images')
      .uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(contentType: 'image/png', upsert: false),
      );
  if (!current()) throw StateError('Session changed');
  return path;
}

/// Signed display URLs are transient presentation values; never save them into
/// catalogue definitions, quotes, issued invoices or image history.
class _CatalogMediaCache {
  _CatalogMediaCache(this.scope);
  final String? scope;
  final clock = Stopwatch()..start();
  final entries = <String, ({String? url, int until})>{};
}

final _catalogMediaCaches = Expando<_CatalogMediaCache>();

Future<void> enrichCatalogImages(
  SupabaseClient client,
  List<Map<String, dynamic>> items,
) async {
  void clearDisplay() {
    for (final item in items) {
      item.remove('image_display_url');
      item.remove('image_path');
      item.remove('image_version');
    }
  }

  clearDisplay();
  final scope = client.auth.currentSession?.accessToken;
  var cache = _catalogMediaCaches[client];
  if (cache == null || cache.scope != scope) {
    cache = _CatalogMediaCache(scope);
    _catalogMediaCaches[client] = cache;
  }
  for (var start = 0; start < items.length; start += 100) {
    final chunk = items.skip(start).take(100).toList();
    for (final item in chunk) {
      item.remove('image_display_url');
      item.remove('image_path');
      item.remove('image_version');
    }
    final response = await client.rpc(
      'get_catalog_image_paths',
      params: {'p_items': chunk.map((x) => x['item_id']).toList()},
    );
    if (client.auth.currentSession?.accessToken != scope) {
      clearDisplay();
      return;
    }
    final images = List<Map<String, dynamic>>.from((response as Map)['images']);
    final missing = <String>[];
    for (final image in images) {
      final path = image['path'] as String;
      for (final item in chunk.where((x) => x['item_id'] == image['item_id'])) {
        item['image_version'] = image['version'];
        item['image_path'] = path;
      }
      final entry = cache.entries[path];
      if (entry == null || entry.until <= cache.clock.elapsedMilliseconds) {
        missing.add(path);
      }
    }
    if (missing.isNotEmpty) {
      try {
        final started = cache.clock.elapsedMilliseconds;
        final signed = await client.storage
            .from('catalog-images')
            .createSignedUrlsResult(missing, 300);
        if (client.auth.currentSession?.accessToken != scope) {
          clearDisplay();
          return;
        }
        for (final result in signed) {
          cache.entries[result.path] = (
            url: result is SignedUrlSuccess ? result.signedUrl : null,
            until: started + (result is SignedUrlSuccess ? 270000 : 15000),
          );
        }
        while (cache.entries.length > 500) {
          cache.entries.remove(cache.entries.keys.first);
        }
      } catch (_) {
        /* Missing images retain the approved fallback. */
      }
    }
    // Signing failure may coincide with logout; do not attach an older capability.
    if (client.auth.currentSession?.accessToken != scope) {
      clearDisplay();
      return;
    }
    for (final item in chunk) {
      final entry = cache.entries[item['image_path']];
      if (entry != null &&
          entry.url != null &&
          entry.until > cache.clock.elapsedMilliseconds) {
        item['image_display_url'] = entry.url;
      }
    }
  }
}
