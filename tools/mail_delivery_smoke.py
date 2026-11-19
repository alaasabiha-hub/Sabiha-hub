"""Exercise real signup/recovery mail through local Auth and Mailpit only."""
import json
import re
import secrets
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text())
base = status['API_URL']
assert urllib.parse.urlsplit(base).hostname == '127.0.0.1'
mail = 'http://127.0.0.1:54324'
email = 'mail-' + secrets.token_hex(6) + '@sabiha.test'
password = secrets.token_urlsafe(24)

def auth(path, data):
    request = urllib.request.Request(base + '/auth/v1/' + path,
        data=json.dumps(data).encode(), headers={
            'apikey': status['ANON_KEY'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

def receive(previous):
    for _ in range(30):
        with urllib.request.urlopen(mail + '/api/v1/messages', timeout=10) as response:
            messages = json.load(response)['messages']
        for message in messages:
            if message['ID'] in previous:
                continue
            if not any(recipient['Address'] == email for recipient in message['To']):
                continue
            with urllib.request.urlopen(mail + '/api/v1/message/' + message['ID'], timeout=10) as response:
                body = json.load(response)
            assert 'Sabiha Hub' in body['HTML']
            token = re.search(r'(?<!\d)\d{6,8}(?!\d)', body['Text'])
            assert token, 'No numeric OTP in local mail'
            previous.add(message['ID'])
            return token.group()
        time.sleep(0.5)
    raise AssertionError('Local mail did not arrive')

seen = set()
signup = auth('signup', {'email': email, 'password': password,
    'data': {'full_name': 'Local mail test', 'phone': 'LOCAL-' + secrets.token_hex(6)}})
assert not signup.get('access_token'), 'Email confirmation should be required'
confirmed = auth('verify', {'email': email, 'token': receive(seen), 'type': 'signup'})
assert confirmed['user']['email_confirmed_at']
print('PASS actual signup mail delivered locally and OTP verified')
auth('recover', {'email': email})
recovered = auth('verify', {'email': email, 'token': receive(seen), 'type': 'recovery'})
assert recovered['user']['id'] == confirmed['user']['id']
print('PASS actual recovery mail delivered locally and OTP verified')
