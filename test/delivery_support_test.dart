import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/delivery_support.dart';
void main(){
 test('WhatsApp only accepts international phone and official hosts',(){
  expect(validInternationalPhone('+201000000001'),isTrue);
  for(final phone in ['012345','+0201','https://evil.test','+20123?text=secret']){expect(validInternationalPhone(phone),isFalse);}
  final link=whatsappSupportUri('+201000000001','طلب SHOP-TEST');
  expect(link.host,'wa.me');expect(link.path,'/201000000001');expect(link.queryParameters['text'],'طلب SHOP-TEST');
  expect(whatsappSupportUri('+201000000001','Test',web:true).host,'web.whatsapp.com');
  expect(()=>whatsappSupportUri('01234','Test'),throwsArgumentError);
 });
 test('pickup skips delivery dispatch and terminal orders stay terminal',(){
  expect(fulfillmentNext('preparing','pickup'),['delivered','cancelled']);
  expect(fulfillmentNext('preparing','delivery'),['out_for_delivery','cancelled']);
  expect(fulfillmentNext('delivered','delivery'),isEmpty);
  expect(fulfillmentNext('cancelled','pickup'),isEmpty);
 });
 test('request ids are unique UUIDs',(){
  final ids=List.generate(100,(_)=>newOrderRequestId());expect(ids.toSet().length,100);expect(ids.first, matches(RegExp(r'^[0-9a-f-]{36}$')));
 });
}
