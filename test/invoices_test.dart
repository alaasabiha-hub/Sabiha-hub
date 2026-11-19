import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';

void main(){
  test('scanning extracts only a UUID and never treats it as invoice authorization',(){
    const token='00000000-0000-4000-8000-000000000123';
    expect(invoiceTokenFromInput('https://example.test/?invoice=$token'),token);
    expect(invoiceTokenFromInput('javascript:alert(1)'),isNull);
    expect(invoiceTokenFromInput('https://example.test/?invoice=someone'),isNull);
  });
  test('same invoice locator is preserved in all paper formats and reprints',() async {
    final doc=<String,dynamic>{'invoice_id':'LOCAL-123','document_token':'00000000-0000-4000-8000-000000000123','portal_origin':'https://sabiha.example.test','issued_at':'2026-11-13','payment_status':'paid','payment_method':'cash','snapshot':{'branch':{'name_ar':'الفرع الرئيسي','name_en':'Main Branch'},'lines':[{'name':'غسيل / Wash','quantity':1,'unit_price':150,'subtotal':150}],'total':140,'discount':10,'tax_amount':null}};
    final font=File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync(),logo=File('assets/sabiha_brand_approved.png').readAsBytesSync();
    for(final paper in ['A4','58','80']) {
      final bytes=await buildInvoicePdf(doc,font,logo,paper:paper,reprint:true);
      expect(String.fromCharCodes(bytes.take(5)),'%PDF-');expect(bytes.length,greaterThan(1000));
    }
    expect(invoiceDocumentUrl(doc),'https://sabiha.example.test/?invoice=${doc['document_token']}');
    expect(()=>invoiceDocumentUrl({...doc,'portal_origin':''}),throwsFormatException);
  });
}
