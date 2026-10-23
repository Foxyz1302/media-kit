import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// {@template faults}
///
/// Faults
/// ------
/// Misbehaviour injected into the responses of one [MediaServer] route.
///
/// {@endtemplate}
class Faults {
  /// {@macro faults}
  const Faults({
    this.latency = Duration.zero,
    this.headerDelay = Duration.zero,
    this.bytesPerSecond,
    this.dropAfterBytes,
    this.stallAfterBytes,
    this.stallFor = Duration.zero,
    this.status,
    this.requests,
    this.then,
  });

  /// Delay before the status line.
  final Duration latency;

  /// Delay before every header line and before the blank line that ends the headers.
  final Duration headerDelay;

  /// Throughput cap for the body.
  final int? bytesPerSecond;

  /// Closes the connection once this many body bytes of the response are sent.
  final int? dropAfterBytes;

  /// Pauses the body for [stallFor] once this many body bytes of the response are sent.
  final int? stallAfterBytes;

  /// Length of the pause requested by [stallAfterBytes].
  final Duration stallFor;

  /// Answers with this status code and an empty body instead of the content, e.g. 404 or 500.
  final int? status;

  /// Applies the faults to the first [requests] requests of the route only. `null` applies them to every request.
  final int? requests;

  /// Faults of the requests after the first [requests]. `null` serves them without faults.
  final Faults? then;

  /// Faults of the request with zero-based [index].
  Faults at(int index) {
    Faults faults = this;
    while (faults.requests != null && index >= faults.requests!) {
      index -= faults.requests!;
      final next = faults.then;
      if (next == null) {
        return const Faults();
      }
      faults = next;
    }
    return faults;
  }
}

/// {@template served_request}
///
/// ServedRequest
/// -------------
/// One request received by a [MediaServer] and what was sent back.
///
/// {@endtemplate}
class ServedRequest {
  /// {@macro served_request}
  ServedRequest(this.method, this.path, this.headers, this.elapsed);

  /// Request method, e.g. `GET`.
  final String method;

  /// Request path, without the query.
  final String path;

  /// Request headers, with lower-case names.
  final Map<String, String> headers;

  /// Time since [MediaServer.start] when the request head was received.
  final Duration elapsed;

  /// Response status code.
  int status = 0;

  /// First byte offset requested by the `Range` header, 0 without one.
  int get rangeStart =>
      int.tryParse(
        RegExp(r'^bytes=(\d+)-').firstMatch(headers['range'] ?? '')?[1] ?? '',
      ) ??
      0;

  /// First byte offset of the response body.
  int start = 0;

  /// Body bytes sent.
  int sent = 0;

  /// Whether a fault closed the connection before the end of the body.
  bool dropped = false;

  /// Whether the client closed the connection before the end of the body.
  bool aborted = false;

  /// Completes when the response is finished, dropped or aborted.
  Future<void> get done => _done.future;

  final Completer<void> _done = Completer<void>();

  @override
  String toString() =>
      'ServedRequest($method $path, range: ${headers['range']}, status: $status, start: $start, sent: $sent, dropped: $dropped, aborted: $aborted)';
}

/// {@template media_server}
///
/// MediaServer
/// -----------
/// A loopback HTTP/1.1 server for media tests.
///
/// It serves in-memory content with byte ranges and HEAD, answers with arbitrary
/// status codes, and injects [Faults]: latency, slow headers, throughput caps,
/// stalls and dropped connections. Every connection is closed after one response.
///
/// {@endtemplate}
class MediaServer {
  MediaServer._(this._server) {
    _server.listen(_handle);
  }

  /// Starts a [MediaServer] on 127.0.0.1 with an ephemeral port.
  static Future<MediaServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return MediaServer._(server);
  }

  /// Port the server listens on.
  int get port => _server.port;

  /// Requests received so far, in arrival order.
  final List<ServedRequest> requests = <ServedRequest>[];

  /// Emits every request once its head is parsed.
  Stream<ServedRequest> get onRequest => _requests.stream;

  /// URL of [path] on this server.
  Uri url(String path) => Uri.parse('http://127.0.0.1:$port$path');

  /// Serves [bytes] at [path].
  Uri serve(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    Faults faults = const Faults(),
  }) {
    _routes[path] = _Route(Uint8List.fromList(bytes), contentType, faults);
    return url(path);
  }

  /// Serves the contents of [file] at [path].
  Uri serveFile(
    String path,
    String file, {
    String? contentType,
    Faults faults = const Faults(),
  }) {
    return serve(
      path,
      File(file).readAsBytesSync(),
      contentType: contentType ?? _contentType(file),
      faults: faults,
    );
  }

  /// Answers every request for [path] with [status] and an empty body.
  Uri fail(String path, int status, {Faults faults = const Faults()}) {
    _routes[path] = _Route(
      Uint8List(0),
      'text/plain',
      Faults(
        latency: faults.latency,
        headerDelay: faults.headerDelay,
        status: status,
      ),
    );
    return url(path);
  }

  /// Replaces the [Faults] of [path]. Its request count starts over.
  void setFaults(String path, Faults faults) {
    final route = _routes[path]!;
    _routes[path] = _Route(route.bytes, route.contentType, faults);
    _counts.remove(path);
  }

  /// Requests received for [path].
  List<ServedRequest> requestsFor(String path) =>
      requests.where((request) => request.path == path).toList();

  /// Stops listening and closes every open connection.
  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _requests.close();
  }

  Future<void> _handle(Socket socket) async {
    _sockets.add(socket);
    socket.done.then((_) {}, onError: (_) {});
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      final head = await _readHead(socket);
      if (head == null) {
        return;
      }
      await _respond(socket, head);
    } catch (_) {
    } finally {
      _sockets.remove(socket);
      socket.destroy();
    }
  }

  Future<String?> _readHead(Socket socket) {
    final completer = Completer<String?>();
    final buffer = BytesBuilder();
    socket.listen(
      (data) {
        if (completer.isCompleted) {
          return;
        }
        buffer.add(data);
        final bytes = buffer.toBytes();
        for (int i = 0; i + 3 < bytes.length; i++) {
          if (bytes[i] == 13 &&
              bytes[i + 1] == 10 &&
              bytes[i + 2] == 13 &&
              bytes[i + 3] == 10) {
            completer.complete(latin1.decode(bytes.sublist(0, i)));
            return;
          }
        }
        if (bytes.length > 65536) {
          completer.complete(null);
        }
      },
      onError: (_) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  Future<void> _respond(Socket socket, String head) async {
    final lines = head.split('\r\n');
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) {
      return;
    }
    final method = requestLine[0].toUpperCase();
    final path = Uri.parse(requestLine[1]).path;
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        headers[line.substring(0, separator).trim().toLowerCase()] =
            line.substring(separator + 1).trim();
      }
    }
    final request = ServedRequest(method, path, headers, _clock.elapsed);
    requests.add(request);
    if (!_requests.isClosed) {
      _requests.add(request);
    }
    try {
      final route = _routes[path];
      final index = _counts[path] = (_counts[path] ?? -1) + 1;
      await _write(
        socket,
        request,
        route,
        route?.faults.at(index) ?? const Faults(),
      );
    } catch (_) {
      request.aborted = true;
    } finally {
      if (!request._done.isCompleted) {
        request._done.complete();
      }
    }
  }

  Future<void> _write(
    Socket socket,
    ServedRequest request,
    _Route? route,
    Faults faults,
  ) async {
    if (faults.latency > Duration.zero) {
      await Future.delayed(faults.latency);
    }
    final total = route?.bytes.length ?? 0;
    var start = 0;
    var end = total - 1;
    final fields = <String, String>{};
    if (route == null) {
      request.status = 404;
    } else if (faults.status != null) {
      request.status = faults.status!;
    } else {
      request.status = 200;
      fields['Content-Type'] = route.contentType;
      fields['Accept-Ranges'] = 'bytes';
      final range = request.headers['range'];
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (match != null && (match[1]!.isNotEmpty || match[2]!.isNotEmpty)) {
        if (match[1]!.isEmpty) {
          start = max(0, total - int.parse(match[2]!));
        } else {
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) {
            end = min(end, int.parse(match[2]!));
          }
        }
        if (start >= total || start > end) {
          request.status = 416;
          fields.remove('Content-Type');
          fields['Content-Range'] = 'bytes */$total';
        } else {
          request.status = 206;
          fields['Content-Range'] = 'bytes $start-$end/$total';
        }
      }
    }
    final length =
        request.status == 200 || request.status == 206 ? end - start + 1 : 0;
    fields['Content-Length'] = '$length';
    fields['Connection'] = 'close';
    request.start = start;

    socket.add(
      latin1
          .encode('HTTP/1.1 ${request.status} ${_reason(request.status)}\r\n'),
    );
    for (final entry in fields.entries) {
      if (faults.headerDelay > Duration.zero) {
        await socket.flush();
        await Future.delayed(faults.headerDelay);
      }
      socket.add(latin1.encode('${entry.key}: ${entry.value}\r\n'));
    }
    if (faults.headerDelay > Duration.zero) {
      await socket.flush();
      await Future.delayed(faults.headerDelay);
    }
    socket.add(latin1.encode('\r\n'));
    await socket.flush();
    if (request.method == 'HEAD' || length == 0) {
      return;
    }

    final body = Uint8List.sublistView(route!.bytes, start, end + 1);
    final pacing = Stopwatch()..start();
    var stalled = false;
    while (request.sent < body.length) {
      if (faults.dropAfterBytes != null &&
          request.sent >= faults.dropAfterBytes!) {
        request.dropped = true;
        return;
      }
      if (faults.stallAfterBytes != null &&
          !stalled &&
          request.sent >= faults.stallAfterBytes!) {
        stalled = true;
        await Future.delayed(faults.stallFor);
        pacing.reset();
      }
      var size = faults.bytesPerSecond == null
          ? 64 * 1024
          : max(1, faults.bytesPerSecond! ~/ 100);
      size = min(size, body.length - request.sent);
      for (final limit in [faults.dropAfterBytes, faults.stallAfterBytes]) {
        if (limit != null && request.sent < limit) {
          size = min(size, limit - request.sent);
        }
      }
      socket.add(
        Uint8List.sublistView(body, request.sent, request.sent + size),
      );
      await socket.flush();
      request.sent += size;
      if (faults.bytesPerSecond != null) {
        final due = Duration(
          microseconds: request.sent * 1000000 ~/ faults.bytesPerSecond!,
        );
        if (due > pacing.elapsed) {
          await Future.delayed(due - pacing.elapsed);
        }
      }
    }
  }

  static String _reason(int status) {
    return const {
          200: 'OK',
          206: 'Partial Content',
          400: 'Bad Request',
          403: 'Forbidden',
          404: 'Not Found',
          416: 'Range Not Satisfiable',
          500: 'Internal Server Error',
          502: 'Bad Gateway',
          503: 'Service Unavailable',
        }[status] ??
        'Status';
  }

  static String _contentType(String file) {
    final extension = file.split('.').last.toLowerCase();
    return const {
          'mp4': 'video/mp4',
          'm4a': 'audio/mp4',
          'mkv': 'video/x-matroska',
          'webm': 'video/webm',
        }[extension] ??
        'application/octet-stream';
  }

  final ServerSocket _server;
  final Map<String, _Route> _routes = <String, _Route>{};
  final Map<String, int> _counts = <String, int>{};
  final Set<Socket> _sockets = <Socket>{};
  final StreamController<ServedRequest> _requests =
      StreamController<ServedRequest>.broadcast();
  final Stopwatch _clock = Stopwatch()..start();
}

class _Route {
  const _Route(this.bytes, this.contentType, this.faults);

  final Uint8List bytes;
  final String contentType;
  final Faults faults;
}
