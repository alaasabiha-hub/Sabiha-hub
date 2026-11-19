import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';
void main(){
  test('render actual synthetic invoice on all Flutter paper sizes',()async{
    final fixture=Platform.environment['SABIHA_INVOICE_FIXTURE'],out=Platform.environment['SABIHA_PDF_OUTPUT_DIR'];
    if(fixture==null || out==null)return;
    final doc=Map<String,dynamic>.from(jsonDecode(File(fixture).readAsStringSync()));
    final font=File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync(),logo=File('assets/sabiha_brand_approved.png').readAsBytesSync();
    for(final paper in ['A4','58','80']){
      final bytes=await buildInvoicePdf(doc,font,logo,paper:paper,reprint:true);
      await File('$out/Sabiha-invoice-flutter-$paper.pdf').writeAsBytes(bytes);expect(bytes.length,greaterThan(1000));
    }
  },skip:Platform.environment['SABIHA_INVOICE_FIXTURE']==null); 
}
