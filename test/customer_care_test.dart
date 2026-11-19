import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_care.dart';
void main(){
 test('attachment types and size limits reject executable or empty content',(){
  expect(safeImageMime(Uint8List(0)),isNull);expect(safeImageMime(Uint8List.fromList('<script>'.codeUnits)),isNull);
  expect(safeImageMime(Uint8List.fromList([137,80,78,71,13,10,26,10])), 'image/png');
  expect(safeImageMime(Uint8List.fromList([255,216,255])), 'image/jpeg');
  expect(safeImageMime(Uint8List.fromList([255,216,255]),maxBytes:2),isNull);
 });
 test('complaint lifecycle requires review and leaves terminal state closed',(){
  expect(complaintNext('new'),['under_review']);expect(complaintNext('in_progress'),['resolved']);expect(complaintNext('closed'),isEmpty);
 });
}
