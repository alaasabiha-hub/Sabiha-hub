// SOURCE ONLY. Root supplies actual server document JSON; no live I/O/API calls.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoice_presentation.dart';
import 'package:sabiha_hub/invoices.dart';

void main() {
  final fixturePath =
      Platform.environment['SABIHA_TYPED_REWARD_DOCUMENT_FIXTURE'];
  test(
    'Actual typed reward issued/cancelled document preserves QR and zero due',
    () async {
      final fixture =
          jsonDecode(await File(fixturePath!).readAsString()) as Map;
      expect(fixture['local_only'], true);
      expect(fixture['canonical_typed_offline_reward'], true);
      final issued = Map<String, dynamic>.from(fixture['issued'] as Map);
      final cancelled = Map<String, dynamic>.from(fixture['cancelled'] as Map);
      expect(issued['reward_coverage']['owner_kind'], 'offline_profile');
      expect(issued['reward_coverage']['source_channel'], 'walk_in');
      expect(invoiceHasRewardCoverage(issued), true);
      expect(invoiceHasRewardCoverage(cancelled), false);
      expect(invoiceHasRewardRecord(cancelled), true);
      expect(cancelled['payment_status'], 'cancelled');
      expect(cancelled['reward_coverage']['state'], 'cancelled_reward');
      expect(issued['invoice_total'], 0);
      expect(
        issued['invoice_discount'],
        issued['reward_coverage']['gross_amount'],
      );
      expect(cancelled['snapshot'], issued['snapshot']);
      expect(cancelled['document_token'], issued['document_token']);
      expect(invoiceDocumentUrl(cancelled), invoiceDocumentUrl(issued));
      expect(fixture['payment_event_count'], 0);
      final before = jsonEncode(issued);
      final font = await File('assets/NotoNaskhArabic-Regular.ttf')
          .readAsBytes();
      final logo = await File('assets/sabiha_brand_approved.png').readAsBytes();
      final output = Platform.environment['SABIHA_TYPED_REWARD_PDF_OUTPUT_DIR'];
      expect(
        output,
        isNotNull,
        reason: 'Explicit QA artifact directory required',
      );
      await Directory(output!).create(recursive: true);
      for (final ar in [true, false]) {
        for (final paper in ['A4', '58', '80']) {
          final bytes = await buildInvoicePdf(
            issued,
            font,
            logo,
            arabic: ar,
            paper: paper,
            reprint: true,
          );
          expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
          await File('$output/typed-reward-${ar ? "ar" : "en"}-$paper.pdf')
              .writeAsBytes(bytes);
        }
      }
      expect(jsonEncode(issued), before);
    },
    skip: fixturePath == null
        ? 'Actual typed server document fixture required; no synthetic acceptance'
        : false,
  );
  test(
    'Actual cancelled typed reward PDF shows cancellation without changing QR',
    () async {
      final fixture =
          jsonDecode(await File(fixturePath!).readAsString()) as Map;
      final issued = Map<String, dynamic>.from(fixture['issued'] as Map);
      final cancelled = Map<String, dynamic>.from(fixture['cancelled'] as Map);
      expect(invoiceHasRewardCoverage(cancelled), false);
      expect(invoiceHasRewardRecord(cancelled), true);
      expect(cancelled['payment_status'], 'cancelled');
      expect(invoiceState(cancelled['payment_status'], true), 'ملغي');
      expect(invoiceState(cancelled['payment_status'], false), 'Cancelled');
      expect(cancelled['snapshot'], issued['snapshot']);
      expect(invoiceDocumentUrl(cancelled), invoiceDocumentUrl(issued));
      final font = await File('assets/NotoNaskhArabic-Regular.ttf')
          .readAsBytes();
      final logo = await File('assets/sabiha_brand_approved.png').readAsBytes();
      final output = Platform.environment['SABIHA_TYPED_REWARD_PDF_OUTPUT_DIR'];
      expect(output, isNotNull);
      final before = jsonEncode(cancelled);
      for (final sample in [(true, '58'), (false, 'A4')]) {
        final bytes = await buildInvoicePdf(
          cancelled,
          font,
          logo,
          arabic: sample.$1,
          paper: sample.$2,
          reprint: true,
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        final language = sample.$1 ? 'ar' : 'en';
        final paper = sample.$2;
        final name = 'typed-reward-cancelled-$language-$paper';
        await File('$output/$name.pdf').writeAsBytes(bytes);
      }
      expect(jsonEncode(cancelled), before);
    },
    skip: fixturePath == null
        ? 'Actual typed cancelled server document required'
        : false,
  );
}
