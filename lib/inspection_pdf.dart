import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> buildInspectionPdf(
  Map<String, dynamic> inspection,
  Map<String, dynamic> visit,
  List<Map<String, dynamic>> media,
  Uint8List arabicFont,
  Uint8List logo,
) async {
  final document = pw.Document(title: 'Sabiha Hub - Vehicle inspection');
  final arFont = pw.Font.ttf(arabicFont.buffer.asByteData()),
      enFont = pw.Font.helvetica();
  pw.Widget text(String value, {double size = 12}) => pw.Text(
    value,
    textDirection: RegExp(r'[\u0600-\u06ff]').hasMatch(value)
        ? pw.TextDirection.rtl
        : pw.TextDirection.ltr,
    style: pw.TextStyle(
      font: RegExp(r'[\u0600-\u06ff]').hasMatch(value) ? arFont : enFont,
      fontFallback: [enFont, arFont],
      fontSize: size,
    ),
  );
  final photos = media.where((m) => m['kind'] != 'signature').toList();
  final signature = media.where((m) => m['kind'] == 'signature').firstOrNull;
  const views = {
    'front': 'الأمام',
    'back': 'الخلف',
    'left': 'الجانب الأيسر',
    'right': 'الجانب الأيمن',
    'interior': 'الداخل',
    'damage': 'ضرر موثق',
  };
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (c) => [
        pw.Center(
          child: pw.Image(pw.MemoryImage(logo), height: 110, width: 180),
        ),
        pw.SizedBox(height: 10),
        text('تقرير فحص السيارة', size: 20),
        text('Vehicle inspection report', size: 17),
        pw.Divider(),
        text(
          inspection['phase'] == 'before' ? 'قبل الخدمة' : 'بعد الخدمة',
          size: 16,
        ),
        text('Revision ${inspection['revision']} - ${inspection['status']}'),
        text('${visit['branch_name_ar']}'),
        text('${visit['branch_name_en']}'),
        text('${visit['vehicle_brand'] ?? ''} ${visit['vehicle_model'] ?? ''}'),
        text('Plate: ${visit['plate_number'] ?? '-'}'),
        text('Booking: ${visit['booking_id']}'),
        text('Created: ${inspection['recorded_at']}'),
        text('Approved: ${inspection['approved_at'] ?? '-'}'),
        text('Inspector: ${inspection['created_by']}'),
        text('Odometer: ${inspection['odometer'] ?? '-'}'),
        if ((visit['invoices'] as List? ?? []).isNotEmpty)
          text(
            'Invoices: ${(visit['invoices'] as List).map((i) => i['invoice_id']).join(', ')}',
          ),
        pw.SizedBox(height: 10),
        text('حالة السيارة والملاحظات', size: 15),
        text('${inspection['vehicle_condition']}'),
        text('${inspection['notes']}'),
        if (inspection['amendment_reason'] != null) ...[
          text('سبب المراجعة'),
          text(inspection['amendment_reason']),
        ],
        pw.SizedBox(height: 10),
        text('مواضع الأضرار', size: 15),
        ...(inspection['damage_markers'] as List? ?? []).map(
          (m) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              text('${views[m['view']] ?? m['view']}'),
              text('${m['type']} | x=${m['x']} y=${m['y']}'),
              text('${m['note'] ?? ''}'),
            ],
          ),
        ),
        pw.SizedBox(height: 10),
        ...photos.map(
          (m) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              text(views[m['kind']] ?? m['kind'], size: 15),
              pw.Image(
                pw.MemoryImage(m['bytes'] as Uint8List),
                height: 220,
                width: 480,
                fit: pw.BoxFit.contain,
              ),
              text('${m['caption'] ?? ''}'),
              text('${m['created_at']}'),
              pw.SizedBox(height: 14),
            ],
          ),
        ),
        text('توثيق التسليم أو الاستلام', size: 15),
        if (signature != null)
          pw.Image(
            pw.MemoryImage(signature['bytes'] as Uint8List),
            height: 90,
            width: 260,
            fit: pw.BoxFit.contain,
          )
        else
          text('${inspection['signature_unavailable_reason'] ?? '-'}'),
        pw.SizedBox(height: 12),
        text('نسخة محلية للاختبار'),
        text(
          'Local test only. Capture record; not a qualified digital certificate.',
          size: 9,
        ),
      ],
    ),
  );
  return document.save();
}
