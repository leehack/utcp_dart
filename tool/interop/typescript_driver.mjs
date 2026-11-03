// TypeScript side of the cross-SDK round trip (see tool/interop/README.md).
//
//   serialize SEEDS          Parse every seed with the TypeScript SDK and
//                            print its serialized form.
//   check SERIALIZED DART    Parse Dart's re-serialization of SERIALIZED
//                            again and require it to serialize to the same
//                            document.
//   accept DART              Require the TypeScript SDK to parse every
//                            document in another SDK's Dart output.
//
// Packages resolve from UTCP_INTEROP_NODE_DIR (default: this directory), the
// directory holding the `npm ci` install of package.json here.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const nodeDir =
  process.env.UTCP_INTEROP_NODE_DIR ?? dirname(fileURLToPath(import.meta.url));
const require = createRequire(join(nodeDir, 'package.json'));

const PACKAGES = [
  '@utcp/sdk',
  '@utcp/http',
  '@utcp/cli',
  '@utcp/mcp',
  '@utcp/text',
  '@utcp/file',
  '@utcp/dotenv-loader',
];
const sdk = require('@utcp/sdk');
for (const name of PACKAGES) require(name);
sdk.ensureCorePluginsInitialized();

// Seeds the TypeScript SDK cannot represent. `serialize` fails when one of
// them starts parsing, so a fixed SDK cannot hide behind a stale entry.
const EXCLUDED = {
  'http/no_body_field':
    'TypeScript has no way to turn off the http body mapping: body_field is a non-nullable string defaulting to "body".',
  'tcp/minimal': 'TypeScript has no tcp transport.',
  'tcp/length_prefix': 'TypeScript has no tcp transport.',
  'tcp/delimiter': 'TypeScript has no tcp transport.',
  'tcp/fixed_length': 'TypeScript has no tcp transport.',
  'udp/minimal': 'TypeScript has no udp transport.',
  'udp/full': 'TypeScript has no udp transport.',
  'websocket/minimal': 'TypeScript has no websocket transport.',
  'websocket/full': 'TypeScript has no websocket transport.',
  'websocket/text_message': 'TypeScript has no websocket transport.',
  'websocket/allowed': 'TypeScript has no websocket transport.',
  'websocket/zero_timeout': 'TypeScript has no websocket transport.',
};

const MISSING = '<missing>';

// Changes Dart's round trip may make: [JSON path pattern, value TypeScript
// wrote, value TypeScript reads back from Dart, why that is the same
// configuration].
const WRITES_DEFAULT =
  'TypeScript keeps nested call templates, auth and MCP server entries as written; Dart writes the default explicitly, which TypeScript reads the same.';
const EXPECTED_DIFFS = [
  [/\.headers$/, MISSING, {}, 'Dart writes absent static headers as {}; TypeScript treats absent and {} alike.'],
  [/\.header_fields$/, MISSING, [], 'Dart writes absent header_fields as []; TypeScript treats absent and [] alike.'],
  [/^\$\.load_variables_from$/, null, [], 'Dart writes no variable loaders as []; TypeScript treats null and [] alike.'],
  [/\.(append_to_final_output|env_vars|working_dir|body_field)$/, null, MISSING,
    'Dart omits optional fields that are null; TypeScript reads null and absent alike.'],
  [/^\$\.timeout$/, 0, 60000,
    'Dart reads streamable_http timeout 0 as the 60 s default and writes that; TypeScript does the same at call time.'],
  [/\.auth\.var_name$/, MISSING, 'X-Api-Key', WRITES_DEFAULT],
  [/\.auth\.var_name$/, MISSING, 'Authorization', WRITES_DEFAULT],
  [/\.auth\.prefix$/, MISSING, 'Bearer ', WRITES_DEFAULT],
  [/\.auth\.location$/, MISSING, 'header', WRITES_DEFAULT],
  [/\.tool_call_template\.http_method$/, MISSING, 'GET', WRITES_DEFAULT],
  [/\.tool_call_template\.content_type$/, MISSING, 'application/json', WRITES_DEFAULT],
  [/\.tool_call_template\.body_field$/, MISSING, 'body', WRITES_DEFAULT],
  [/\.tool_call_template\.reconnect$/, MISSING, true, WRITES_DEFAULT],
  [/\.tool_call_template\.retry_timeout$/, MISSING, 30000, WRITES_DEFAULT],
  [/\.mcpServers\.\w+\.transport$/, MISSING, 'stdio', 'Dart writes the transport it inferred from `command`.'],
  [/\.mcpServers\.\w+\.env$/, MISSING, {}, WRITES_DEFAULT],
  [/\.mcpServers\.\w+\.timeout$/, MISSING, 30, WRITES_DEFAULT],
  [/\.mcpServers\.\w+\.sse_read_timeout$/, MISSING, 300, WRITES_DEFAULT],
  [/\.mcpServers\.\w+\.terminate_on_close$/, MISSING, true, WRITES_DEFAULT],
  [/\.mcpServers\.\w+\.notification_stream_max_retries$/, MISSING, 0, WRITES_DEFAULT],
];

// Documents from another SDK, re-serialized by Dart, that TypeScript cannot
// parse: { source SDK: { seed id: reason } }. `accept` fails when one of
// them starts parsing.
const ACCEPT_EXCLUDED = {};

const SERIALIZERS = {
  call_template: sdk.CallTemplateSerializer,
  manual: sdk.UtcpManualSerializer,
  config: sdk.UtcpClientConfigSerializer,
};
const SEED_SECTIONS = { call_templates: 'call_template', manuals: 'manual', configs: 'config' };

function roundTrip(kind, document) {
  const serializer = new SERIALIZERS[kind]();
  return JSON.parse(JSON.stringify(serializer.toDict(serializer.validateDict(document))));
}

const load = (path) => JSON.parse(readFileSync(path, 'utf8'));
const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
const sameValue = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const firstLine = (error) => String(error?.message ?? error).split('\n    at ')[0].replace(/\s+/g, ' ').slice(0, 400);

function* diff(expected, actual, path = '$') {
  if (isObject(expected) && isObject(actual)) {
    const keys = [...new Set([...Object.keys(expected), ...Object.keys(actual)])].sort();
    for (const key of keys) {
      yield* diff(key in expected ? expected[key] : MISSING, key in actual ? actual[key] : MISSING, `${path}.${key}`);
    }
  } else if (Array.isArray(expected) && Array.isArray(actual) && expected.length === actual.length) {
    for (let i = 0; i < expected.length; i++) yield* diff(expected[i], actual[i], `${path}[${i}]`);
  } else if (!sameValue(expected, actual)) {
    yield [path, expected, actual];
  }
}

function expectedDiff(path, before, after) {
  return EXPECTED_DIFFS.find(
    ([pattern, old, now]) => pattern.test(path) && sameValue(old, before) && sameValue(now, after),
  );
}

function serialize(seedsPath) {
  const seeds = load(seedsPath);
  const documents = [];
  const failures = [];
  for (const [section, kind] of Object.entries(SEED_SECTIONS)) {
    for (const [id, seed] of Object.entries(seeds[section])) {
      let serialized;
      try {
        serialized = roundTrip(kind, seed);
      } catch (error) {
        if (!(id in EXCLUDED)) failures.push(`${id}: TypeScript rejects the seed: ${firstLine(error)}`);
        continue;
      }
      if (id in EXCLUDED) {
        failures.push(`${id}: excluded (${EXCLUDED[id]}) but TypeScript now parses it`);
        continue;
      }
      documents.push({ id, kind, json: serialized });
    }
  }
  for (const [id, reason] of Object.entries(EXCLUDED)) {
    console.error(`typescript: excluded ${id}: ${reason}`);
  }
  const versions = Object.fromEntries(
    PACKAGES.map((name) => [name, load(join(nodeDir, 'node_modules', name, 'package.json')).version]),
  );
  process.stdout.write(`${JSON.stringify({ sdk: 'typescript', versions, documents }, null, 2)}\n`);
  return failures;
}

function check(serializedPath, dartPath) {
  const originals = load(serializedPath).documents;
  const dart = new Map(load(dartPath).documents.map((d) => [d.id, d]));
  const failures = [];
  const used = new Set();
  for (const original of originals) {
    const output = dart.get(original.id);
    if (output === undefined || 'error' in output) {
      failures.push(`${original.id}: Dart failed: ${output?.error}`);
      continue;
    }
    let again;
    try {
      again = roundTrip(original.kind, output.json);
    } catch (error) {
      failures.push(`${original.id}: TypeScript rejects Dart's output: ${firstLine(error)}`);
      continue;
    }
    for (const [path, before, after] of diff(original.json, again)) {
      const expected = expectedDiff(path, before, after);
      if (expected === undefined) {
        failures.push(`${original.id}: ${path} changed: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
      }
      used.add(expected);
    }
  }
  for (const entry of EXPECTED_DIFFS) {
    if (!used.has(entry)) failures.push(`expected diff ${entry[0]} (${entry[3]}) no longer occurs; remove it`);
  }
  console.error(`typescript: checked ${originals.length} documents from ${serializedPath}`);
  return failures;
}

function accept(dartPath) {
  const { source, documents } = load(dartPath);
  const excluded = ACCEPT_EXCLUDED[source] ?? {};
  const failures = [];
  let checked = 0;
  for (const output of documents) {
    if (output.id in EXCLUDED || 'error' in output) continue;
    checked++;
    try {
      roundTrip(output.kind, output.json);
    } catch (error) {
      if (!(output.id in excluded)) {
        failures.push(`${output.id}: TypeScript rejects Dart's output: ${firstLine(error)}`);
      }
      continue;
    }
    if (output.id in excluded) {
      failures.push(`${output.id}: excluded for ${source} (${excluded[output.id]}) but TypeScript now parses it`);
    }
  }
  for (const [id, reason] of Object.entries(excluded)) {
    console.error(`typescript: excluded ${source} ${id}: ${reason}`);
  }
  console.error(`typescript: accepted ${checked} documents from ${dartPath}`);
  return failures;
}

const COMMANDS = { serialize: [serialize, 1], check: [check, 2], accept: [accept, 1] };
const [command, ...args] = process.argv.slice(2);
if (!(command in COMMANDS) || args.length !== COMMANDS[command][1]) {
  console.error('Usage: typescript_driver.mjs serialize SEEDS | check SERIALIZED DART | accept DART');
  process.exit(2);
}
const failures = COMMANDS[command][0](...args);
for (const failure of failures) console.error(`typescript: FAIL ${failure}`);
process.exit(failures.length === 0 ? 0 : 1);
