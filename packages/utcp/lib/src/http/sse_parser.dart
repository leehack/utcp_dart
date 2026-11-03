import 'dart:convert';

import '../exceptions.dart';

/// One dispatched event. Fields absent from the event block are `null`.
final class SseEvent {
  const SseEvent({this.event, this.data, this.id, this.retry});

  final String? event;

  /// The `data:` lines joined with `\n`.
  final String? data;
  final String? id;

  /// Reconnection time in milliseconds.
  final int? retry;
}

/// Parses an `text/event-stream` body as the WHATWG HTML specification
/// describes: CRLF, CR or LF line endings, comments, multi-line `data:`, and
/// chunk boundaries anywhere, including inside a line, a CRLF pair or a UTF-8
/// sequence. An event left unterminated at the end of the stream is
/// discarded. Throws [SseProtocolException] once an event exceeds
/// [maxEventChars] UTF-16 code units.
Stream<SseEvent> parseSseEvents(
  Stream<List<int>> bytes, {
  required int maxEventChars,
}) async* {
  final parser = _SseParser(maxEventChars);
  await for (final text in bytes.transform(
    const Utf8Decoder(allowMalformed: true),
  )) {
    for (final event in parser.add(text)) {
      yield event;
    }
  }
}

final class _SseParser {
  _SseParser(this.maxEventChars);

  final int maxEventChars;

  static const _cr = 0x0D;
  static const _lf = 0x0A;
  // Upper bound for an overflowing `retry:` value; callers cap it anyway.
  static const _maxRetry = 9007199254740991;
  static final _digits = RegExp(r'^[0-9]+$');

  final _line = StringBuffer();
  var _atStart = true;
  var _afterCr = false;
  var _eventChars = 0;
  var _hasFields = false;
  String? _event;
  String? _id;
  int? _retry;
  List<String>? _data;

  List<SseEvent> add(String text) {
    if (_atStart && text.isNotEmpty) {
      _atStart = false;
      if (text.startsWith('﻿')) text = text.substring(1);
    }
    final events = <SseEvent>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (_afterCr && unit == _lf) {
        _afterCr = false;
        start = i + 1;
        continue;
      }
      _afterCr = false;
      if (unit == _cr || unit == _lf) {
        _line.write(text.substring(start, i));
        _endLine(events);
        _afterCr = unit == _cr;
        start = i + 1;
      }
    }
    _line.write(text.substring(start));
    _checkSize(_line.length);
    return events;
  }

  void _endLine(List<SseEvent> events) {
    final line = _line.toString();
    _line.clear();
    if (line.isEmpty) {
      _dispatch(events);
      return;
    }
    _eventChars += line.length + 1;
    _checkSize(0);
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        (_data ??= []).add(value);
      // An id containing NUL is ignored, per the specification.
      case 'id' when !value.contains('\u0000'):
        _id = value;
      case 'retry' when _digits.hasMatch(value):
        _retry = int.tryParse(value) ?? _maxRetry;
      default:
        return;
    }
    _hasFields = true;
  }

  void _dispatch(List<SseEvent> events) {
    if (_hasFields) {
      events.add(
        SseEvent(
          event: _event,
          data: _data?.join('\n'),
          id: _id,
          retry: _retry,
        ),
      );
    }
    _hasFields = false;
    _eventChars = 0;
    _event = _id = null;
    _retry = null;
    _data = null;
  }

  void _checkSize(int pending) {
    if (_eventChars + pending > maxEventChars) {
      throw SseProtocolException(
        'SSE event exceeded $maxEventChars characters without a blank-line '
        'delimiter.',
      );
    }
  }
}
