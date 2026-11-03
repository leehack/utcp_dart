@TestOn('vm')
library;

import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:test/test.dart';
import 'package:utcp_mcp/src/stdio_transport.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

void main() {
  // The child's configuration is private to mcp_dart; the stdio integration
  // tests check it on a running server.
  test('opens a stdio transport without starting the child', () {
    final transport = openStdioTransport(
      const McpStdioServer(command: 'mcp-files-that-does-not-exist'),
    );
    expect(transport, isA<mcp.StdioClientTransport>());
  });

  test('recognizes process and pipe failures', () {
    expect(isIOException(const ProcessException('mcp-files', [])), isTrue);
    expect(isIOException(StateError('closed')), isFalse);
  });
}
