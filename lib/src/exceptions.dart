/// Base class for errors raised by the UTCP client.
class UtcpException implements Exception {
  const UtcpException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A `${VAR}` placeholder could not be resolved from config variables,
/// variable loaders, or the environment.
class UtcpVariableNotFoundException extends UtcpException {
  UtcpVariableNotFoundException(this.variableName)
    : super(
        "Variable '$variableName' was not found in config variables, "
        'variable loaders, or the environment.',
      );

  final String variableName;
}

/// A request was refused because it could expose credentials or reach an
/// address the manual was not allowed to target.
class UtcpSecurityException extends UtcpException {
  const UtcpSecurityException(super.message);
}

/// A tool or discovery endpoint answered with an HTTP error status.
class UtcpHttpException extends UtcpException {
  const UtcpHttpException(super.message, {required this.statusCode, this.body});

  final int statusCode;

  /// The decoded response body (JSON value or text).
  final Object? body;
}
