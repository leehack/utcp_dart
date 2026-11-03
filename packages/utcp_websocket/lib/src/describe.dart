/// [uri] without user info, query or fragment, which may carry credentials,
/// for error messages and logs.
String describeUrl(Uri uri) => Uri(
  scheme: uri.scheme,
  host: uri.host,
  port: uri.hasPort ? uri.port : null,
  path: uri.path,
).toString();

/// [describeUrl] for a URL that may not parse.
String describeUrlString(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri == null ? 'an unparsable URL' : describeUrl(uri);
}
