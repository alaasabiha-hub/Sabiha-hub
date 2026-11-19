import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/notification_campaign_media.dart';

void main() {
  test('recognizes PNG bytes and derives MIME from the file signature', () {
    final asset = NotificationCampaignImage.validate(
      bytes: const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      extension: 'png',
    );
    expect(asset.extension, 'png');
    expect(asset.contentType, 'image/png');
  });

  test('accepts JPEG and WebP only when extension agrees', () {
    final jpeg = NotificationCampaignImage.validate(
      bytes: const [0xff, 0xd8, 0xff],
      extension: 'jpeg',
    );
    expect(jpeg.contentType, 'image/jpeg');
    expect(jpeg.extension, 'jpg');
    final webp = NotificationCampaignImage.validate(
      bytes: const [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50],
      extension: 'webp',
    );
    expect(webp.contentType, 'image/webp');
    expect(
      () => NotificationCampaignImage.validate(
        bytes: const [0xff, 0xd8, 0xff],
        extension: 'png',
      ),
      throwsFormatException,
    );
    expect(
      () => NotificationCampaignImage.validate(
        bytes: const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
        extension: 'jpg',
      ),
      throwsFormatException,
    );
  });

  test('rejects unrecognized, empty and oversized files', () {
    expect(
      () =>
          NotificationCampaignImage.validate(bytes: const [], extension: 'png'),
      throwsFormatException,
    );
    expect(
      () => NotificationCampaignImage.validate(
        bytes: const [1, 2, 3],
        extension: 'jpg',
      ),
      throwsFormatException,
    );
    expect(
      () => NotificationCampaignImage.validate(
        bytes: List<int>.filled(maxCampaignImageBytes + 1, 0),
        extension: 'png',
      ),
      throwsFormatException,
    );
  });
}
