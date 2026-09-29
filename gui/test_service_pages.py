import http.client
import json
import threading
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer

from gui import server as gui_server


class FakeResponse:
    status = 200
    headers = {'Content-Type': 'application/json'}

    def __init__(self, body=b'[]'):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self.body


class QuietHandler(gui_server.Handler):
    def log_message(self, *_):
        pass


class ServicePageProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(('127.0.0.1', 0), QuietHandler)
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.httpd.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=2)

    def call(self, method, path, body=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        payload = json.dumps(body).encode() if body is not None else None
        headers = {'Content-Type': 'application/json'} if payload is not None else {}
        connection.request(method, path, body=payload, headers=headers)
        response = connection.getresponse()
        data = response.read()
        result = (response.status, data)
        connection.close()
        return result

    def test_fixed_targets_and_crud_methods(self):
        cases = [
            ('product', '/api/products', 18081, '/api/products'),
            ('inventory', '/api/inventory', 18082, '/api/inventory'),
            ('order', '/api/orders', 18083, '/api/orders'),
        ]
        for service, collection, port, upstream_collection in cases:
            with self.subTest(service=service):
                seen = []

                def fake_urlopen(request, timeout):
                    seen.append((request.get_method(), request.full_url, request.data, timeout))
                    return FakeResponse(b'{"ok":true}')

                with patch.object(gui_server, 'urlopen', side_effect=fake_urlopen):
                    self.assertEqual(200, self.call('GET', f'/api/services/{service}')[0])
                    self.assertEqual(200, self.call('POST', f'/api/services/{service}', {'example': 1})[0])
                    self.assertEqual(200, self.call('PUT', f'/api/services/{service}/17', {'example': 2})[0])
                    self.assertEqual(200, self.call('DELETE', f'/api/services/{service}/17')[0])
                    self.assertEqual(200, self.call('GET', f'/api/services/{service}/health')[0])

                self.assertEqual(5, len(seen))
                self.assertEqual(
                    [
                        ('GET', f'http://127.0.0.1:{port}{upstream_collection}', None, 5),
                        ('POST', f'http://127.0.0.1:{port}{upstream_collection}', b'{"example": 1}', 5),
                        ('PUT', f'http://127.0.0.1:{port}{upstream_collection}/17', b'{"example": 2}', 5),
                        ('DELETE', f'http://127.0.0.1:{port}{upstream_collection}/17', None, 5),
                        ('GET', f'http://127.0.0.1:{port}/actuator/health', None, 5),
                    ],
                    seen,
                )

    def test_arbitrary_target_and_invalid_methods_are_rejected(self):
        with patch.object(gui_server, 'urlopen') as upstream:
            self.assertEqual(404, self.call('GET', '/api/services/product?url=http://example.test')[0])
            self.assertEqual(404, self.call('GET', '/api/services/unknown')[0])
            self.assertEqual(405, self.call('PUT', '/api/services/product')[0])
            self.assertEqual(405, self.call('POST', '/api/services/order/3', {'productId': 1, 'quantity': 1})[0])
            upstream.assert_not_called()

    def test_invalid_json_body_is_rejected_without_upstream_request(self):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        connection.request('POST', '/api/services/product', body=b'[]', headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(400, response.status)


if __name__ == '__main__':
    unittest.main()
