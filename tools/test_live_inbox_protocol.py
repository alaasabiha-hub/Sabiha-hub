"""Offline synthetic checks of pinned Realtime2 receive format; no app/DB/network."""
import json
import unittest
from live_inbox_ui_browser import decode_inbox_frame, validate_inbox_hint, hint_shape

ACTOR = '11111111-1111-4111-8111-111111111111'
TRANSPORT = '22222222-2222-4222-8222-222222222222'
TOPIC = 'realtime:app-inbox:' + ACTOR


def frame(body=None, meta=None):
    payload = {'type': 'broadcast', 'event': 'inbox_changed',
               'payload': body if body is not None else {'kind': 'inbox_changed'}}
    if meta is not None:
        payload['meta'] = meta
    return {'join_ref': None, 'ref': None, 'topic': TOPIC, 'event': 'broadcast', 'payload': payload}


def binary(body, meta=None):
    topic, event = TOPIC.encode(), b'inbox_changed'
    metadata = json.dumps(meta).encode() if meta is not None else b''
    return bytes([4, len(topic), len(event), len(metadata), 1]) + topic + event + metadata + json.dumps(body).encode()


class ProtocolTest(unittest.TestCase):
    def test_v1_object_and_v2_array_keep_managed_body_id(self):
        original = frame({'kind': 'inbox_changed', 'id': TRANSPORT})
        for raw in (json.dumps(original), json.dumps(list(original.values()))):
            decoded, _ = decode_inbox_frame(raw)
            self.assertEqual(decoded, original)
            validate_inbox_hint(decoded, {ACTOR})

    def test_pinned_binary_kind4_json_metadata_id_roundtrip(self):
        original = frame(meta={'id': TRANSPORT})
        decoded, diagnostic = decode_inbox_frame(binary({'kind': 'inbox_changed'}, {'id': TRANSPORT}))
        self.assertEqual(decoded, original)
        self.assertEqual(diagnostic['encoding'], 1)
        validate_inbox_hint(decoded, {ACTOR})
        shape = hint_shape(decoded, diagnostic, TOPIC)
        self.assertTrue(shape['meta_id_is_uuid'])
        self.assertTrue(shape['topic_matches_actor'])
        encoded = json.dumps(shape)
        self.assertNotIn(TRANSPORT, encoded)
        self.assertNotIn(ACTOR, encoded)

    def test_binary_retained_body_id_and_strict_invalid_header(self):
        decoded, _ = decode_inbox_frame(binary({'kind': 'inbox_changed', 'id': TRANSPORT}))
        validate_inbox_hint(decoded, {ACTOR})
        raw = binary({'kind': 'inbox_changed'}, {'id': TRANSPORT})
        for invalid in (raw[:4], bytes([3]) + raw[1:], raw[:4] + bytes([0]) + raw[5:], bytes([4, 255, 255, 255, 1])):
            with self.assertRaises((AssertionError, ValueError)):
                decode_inbox_frame(invalid)

    def test_missing_business_or_mismatched_transport_ids_fail_closed(self):
        candidates = [frame(), frame({'kind': 'inbox_changed', 'id': ACTOR}),
                      frame({'kind': 'inbox_changed', 'phone': 'synthetic'}),
                      frame(meta={'id': TRANSPORT, 'case_id': ACTOR}),
                      frame({'kind': 'inbox_changed', 'id': TRANSPORT}, {'id': ACTOR})]
        for candidate in candidates:
            with self.assertRaises((AssertionError, ValueError)):
                validate_inbox_hint(candidate, {ACTOR})


if __name__ == '__main__':
    unittest.main()
