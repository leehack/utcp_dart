/// [uri] without user info, query or fragment, which may carry credentials,
/// for error messages.
String describeUrl(Uri uri) => Uri(
  scheme: uri.scheme,
  host: uri.host,
  port: uri.hasPort ? uri.port : null,
  path: uri.path,
).toString();
