import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/free_owner_assistant.dart';

void main() {
  test('current local Edge response satisfies shared evidence contract', () {
    final path = Platform.environment['SABIHA_CHAT_DIAGNOSTIC_FILE'];
    if (path == null) {
      throw StateError('Explicit isolated response file required');
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(File(path).readAsStringSync()) as Map,
    );
    expect(
      validFreeOwnerEvidence(
        data,
        data['topic'] as String,
        data['period']['from'] as String,
        data['period']['to'] as String,
      ),
      isTrue,
    );
  }, skip: Platform.environment['SABIHA_CHAT_DIAGNOSTIC_FILE'] == null);
}
