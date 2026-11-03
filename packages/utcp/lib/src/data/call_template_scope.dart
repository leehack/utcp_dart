import 'dart:async';

import '../registry.dart';
import 'call_template.dart';

final _registryKey = Object();

/// Runs [body] so that [CallTemplate.fromJson] inside it, across awaits,
/// parses with [registry]. A client uses this to parse with its own
/// protocols even where a transport calls [CallTemplate.fromJson] itself.
R withCallTemplateRegistry<R>(
  TypeRegistry<CallTemplate> registry,
  R Function() body,
) => runZoned(body, zoneValues: {_registryKey: registry});

/// The registry set by [withCallTemplateRegistry], if any.
TypeRegistry<CallTemplate>? get scopedCallTemplateRegistry =>
    switch (Zone.current[_registryKey]) {
      final TypeRegistry<CallTemplate> registry => registry,
      _ => null,
    };
