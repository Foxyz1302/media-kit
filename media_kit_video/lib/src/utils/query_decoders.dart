/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:collection';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';
import 'package:synchronized/synchronized.dart';

/// Returns the list of available decoders available in libavcodec.
///
/// Read through [player]'s asynchronous API: a synchronous read would block this isolate while
/// mpv's core is busy (e.g. opening an audio device).
///
/// https://mpv.io/manual/stable/#command-interface-decoder-list
Future<HashSet<String>> queryDecoders(Player player) {
  return _lock.synchronized(() async {
    if (_decoders.isNotEmpty) {
      return _decoders;
    }
    final platform = player.platform;
    if (platform is! NativePlayer) {
      return _decoders;
    }
    // mpv gives a node property as JSON when it's read as a string.
    final json = await platform.getProperty(
      'decoder-list',
      waitForInitialization: false,
    );
    try {
      final list = jsonDecode(json);
      if (list is List) {
        for (final decoder in list) {
          if (decoder is Map) {
            final name = decoder['codec'] ?? decoder['driver'];
            if (name is String) {
              _decoders.add(name);
            }
          }
        }
      }
    } on FormatException catch (exception) {
      print('media_kit: queryDecoders: $exception');
    }
    return _decoders;
  });
}

final Lock _lock = Lock();
final HashSet<String> _decoders = HashSet<String>();
