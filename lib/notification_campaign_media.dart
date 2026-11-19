import 'dart:typed_data';

const maxCampaignImageBytes = 3 * 1024 * 1024;

class NotificationCampaignImage {
  const NotificationCampaignImage({
    required this.bytes,
    required this.extension,
    required this.contentType,
  });

  final Uint8List bytes;
  final String extension;
  final String contentType;

  static NotificationCampaignImage validate({
    required List<int>? bytes,
    required String? extension,
  }) {
    if (bytes == null ||
        bytes.isEmpty ||
        bytes.length > maxCampaignImageBytes) {
      throw const FormatException('Image must be between 1 byte and 3 MiB.');
    }
    final data = Uint8List.fromList(bytes);
    final ext = extension?.toLowerCase().replaceFirst('.', '');
    if (data.length >= 8 &&
        data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4e &&
        data[3] == 0x47 &&
        data[4] == 0x0d &&
        data[5] == 0x0a &&
        data[6] == 0x1a &&
        data[7] == 0x0a) {
      if (ext != 'png') {
        throw const FormatException('Image extension does not match its file.');
      }
      return NotificationCampaignImage(
        bytes: data,
        extension: 'png',
        contentType: 'image/png',
      );
    }
    if (data.length >= 3 &&
        data[0] == 0xff &&
        data[1] == 0xd8 &&
        data[2] == 0xff) {
      if (ext != 'jpg' && ext != 'jpeg') {
        throw const FormatException('Image extension does not match its file.');
      }
      return NotificationCampaignImage(
        bytes: data,
        extension: 'jpg',
        contentType: 'image/jpeg',
      );
    }
    if (data.length >= 12 &&
        data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      if (ext != 'webp') {
        throw const FormatException('Image extension does not match its file.');
      }
      return NotificationCampaignImage(
        bytes: data,
        extension: 'webp',
        contentType: 'image/webp',
      );
    }
    throw const FormatException('Choose a real JPEG, PNG, or WebP image.');
  }
}
