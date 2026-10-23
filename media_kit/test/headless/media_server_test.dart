@TestOn('linux')
@Tags(['headless'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../common/media_server.dart';

class _Response {
  _Response(
      this.status, this.headers, this.body, this.headersAt, this.closedAt);

  final int status;
  final Map<String, String> headers;
  final Uint8List body;
  final Duration headersAt;
  final Duration closedAt;

  bool get complete => body.length == int.parse(headers['content-length']!);
}

int _headEnd(Uint8List bytes) {
  for (int i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

Future<_Response> _request(
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final clock = Stopwatch()..start();
  final socket = await Socket.connect(url.host, url.port);
  final request = StringBuffer('$method ${url.path} HTTP/1.1\r\n')
    ..write('Host: ${url.host}:${url.port}\r\n');
  headers.forEach((name, value) => request.write('$name: $value\r\n'));
  request.write('\r\n');
  socket.add(latin1.encode(request.toString()));
  final received = BytesBuilder();
  Duration? headersAt;
  try {
    await for (final chunk in socket) {
      received.add(chunk);
      if (headersAt == null && _headEnd(received.toBytes()) >= 0) {
        headersAt = clock.elapsed;
      }
    }
  } on SocketException {
    headersAt ??= clock.elapsed;
  }
  socket.destroy();
  final bytes = received.toBytes();
  final end = _headEnd(bytes);
  final lines = latin1.decode(bytes.sublist(0, end)).split('\r\n');
  return _Response(
    int.parse(lines.first.split(' ')[1]),
    {
      for (final line in lines.skip(1))
        line.substring(0, line.indexOf(':')).toLowerCase():
            line.substring(line.indexOf(':') + 1).trim(),
    },
    bytes.sublist(end + 4),
    headersAt!,
    clock.elapsed,
  );
}

void main() {
  final content = Uint8List.fromList(
    List<int>.generate(200000, (i) => (i * 7 + i ~/ 256) % 256),
  );
  late MediaServer server;

  setUp(() async {
    server = await MediaServer.start();
  });
  tearDown(() async {
    await server.close();
  });

  test('media-server-full-body', () async {
    final response = await _request(server.serve('/a.mp4', content));
    expect(response.status, 200);
    expect(response.headers['content-length'], '${content.length}');
    expect(response.headers['accept-ranges'], 'bytes');
    expect(response.headers['content-type'], 'application/octet-stream');
    expect(response.headers['connection'], 'close');
    expect(response.body, content);
  });
  test('media-server-byte-ranges', () async {
    final url = server.serve('/a.mp4', content);
    final closed = await _request(url, headers: {'Range': 'bytes=10-19'});
    expect(closed.status, 206);
    expect(closed.headers['content-range'], 'bytes 10-19/${content.length}');
    expect(closed.body, content.sublist(10, 20));
    final open = await _request(url, headers: {'Range': 'bytes=150000-'});
    expect(open.status, 206);
    expect(
      open.headers['content-range'],
      'bytes 150000-${content.length - 1}/${content.length}',
    );
    expect(open.body, content.sublist(150000));
    final suffix = await _request(url, headers: {'Range': 'bytes=-5'});
    expect(suffix.status, 206);
    expect(suffix.body, content.sublist(content.length - 5));
    final clamped =
        await _request(url, headers: {'Range': 'bytes=199990-300000'});
    expect(clamped.status, 206);
    expect(clamped.body, content.sublist(199990));
  });
  test('media-server-unsatisfiable-range', () async {
    final url = server.serve('/a.mp4', content);
    final response = await _request(url, headers: {'Range': 'bytes=200000-'});
    expect(response.status, 416);
    expect(response.headers['content-range'], 'bytes */${content.length}');
    expect(response.body, isEmpty);
  });
  test('media-server-head', () async {
    final url = server.serve('/a.mp4', content, contentType: 'video/mp4');
    final response = await _request(url, method: 'HEAD');
    expect(response.status, 200);
    expect(response.headers['content-length'], '${content.length}');
    expect(response.headers['content-type'], 'video/mp4');
    expect(response.body, isEmpty);
  });
  test('media-server-status-codes', () async {
    expect((await _request(server.url('/missing.mp4'))).status, 404);
    expect((await _request(server.fail('/broken.mp4', 500))).status, 500);
    expect((await _request(server.fail('/denied.mp4', 403))).status, 403);
    final once = server.serve(
      '/flaky.mp4',
      content,
      faults: const Faults(status: 503, requests: 1),
    );
    expect((await _request(once)).status, 503);
    final second = await _request(once);
    expect(second.status, 200);
    expect(second.body, content);
  });
  test('media-server-records-requests', () async {
    final url = server.serve('/a.mp4', content);
    final arrived = server.onRequest.first;
    await _request(url, headers: {'X-Foo': 'bar', 'Range': 'bytes=5-9'});
    final request = await arrived;
    expect(request.method, 'GET');
    expect(request.path, '/a.mp4');
    expect(request.headers['x-foo'], 'bar');
    expect(request.headers['range'], 'bytes=5-9');
    expect(request.status, 206);
    expect(request.start, 5);
    expect(request.sent, 5);
    expect(server.requestsFor('/a.mp4'), [request]);
  });
  test('media-server-latency', () async {
    final url = server.serve(
      '/a.mp4',
      content,
      faults: const Faults(latency: Duration(milliseconds: 400)),
    );
    final response = await _request(url);
    expect(response.headersAt,
        greaterThanOrEqualTo(const Duration(milliseconds: 400)));
    expect(response.complete, isTrue);
  });
  test('media-server-slow-headers', () async {
    final url = server.serve(
      '/a.mp4',
      content,
      faults: const Faults(headerDelay: Duration(milliseconds: 100)),
    );
    final response = await _request(url);
    expect(response.headersAt,
        greaterThanOrEqualTo(const Duration(milliseconds: 500)));
    expect(response.complete, isTrue);
  });
  test('media-server-throughput', () async {
    final url = server.serve(
      '/a.mp4',
      content,
      faults: const Faults(bytesPerSecond: 400000),
    );
    final response = await _request(url);
    expect(response.complete, isTrue);
    expect(response.closedAt,
        greaterThanOrEqualTo(const Duration(milliseconds: 490)));
    expect(response.closedAt, lessThan(const Duration(seconds: 3)));
  });
  test('media-server-drop-after-bytes', () async {
    final url = server.serve(
      '/a.mp4',
      content,
      faults: const Faults(dropAfterBytes: 12345, requests: 1),
    );
    final first = await _request(url);
    expect(first.status, 200);
    expect(first.body, content.sublist(0, 12345));
    expect(first.complete, isFalse);
    final second = await _request(url, headers: {'Range': 'bytes=12345-'});
    expect(second.status, 206);
    expect(second.body, content.sublist(12345));
    final requests = server.requestsFor('/a.mp4');
    expect(requests.map((request) => request.dropped), [true, false]);
  });
  test('media-server-stall', () async {
    final url = server.serve(
      '/a.mp4',
      content,
      faults: const Faults(
        stallAfterBytes: 1000,
        stallFor: Duration(milliseconds: 600),
      ),
    );
    final response = await _request(url);
    expect(response.complete, isTrue);
    expect(response.body, content);
    expect(response.closedAt,
        greaterThanOrEqualTo(const Duration(milliseconds: 600)));
  });
  test('media-server-close-drops-connections', () async {
    final url = server.serve(
      '/a.mp4',
      content,
      faults: const Faults(bytesPerSecond: 1000),
    );
    final pending = _request(url);
    await server.onRequest.first;
    await Future.delayed(const Duration(milliseconds: 200));
    await server.close();
    final response = await pending.timeout(const Duration(seconds: 5));
    expect(response.complete, isFalse);
  });
}
