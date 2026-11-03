"""Python side of the cross-SDK round trip (see tool/interop/README.md).

serialize SEEDS          Parse every seed with the Python SDK and print its
                         serialized form.
check SERIALIZED DART    Parse Dart's re-serialization of SERIALIZED again and
                         require it to serialize to the same document.
accept DART              Require the Python SDK to parse every document in
                         another SDK's Dart output.
"""

import json
import logging
import re
import sys
from importlib.metadata import version

logging.disable(logging.CRITICAL)

from utcp.data.call_template import CallTemplateSerializer  # noqa: E402
from utcp.data.utcp_client_config import UtcpClientConfigSerializer  # noqa: E402
from utcp.data.utcp_manual import UtcpManualSerializer  # noqa: E402
from utcp.plugins.plugin_loader import ensure_plugins_initialized  # noqa: E402

SDK = "python"
DISTRIBUTIONS = [
    "utcp", "utcp-http", "utcp-cli", "utcp-mcp", "utcp-text", "utcp-file",
    "utcp-socket", "utcp-websocket",
]

# Seeds the Python SDK cannot represent. `serialize` fails when one of them
# starts parsing, so a fixed SDK cannot hide behind a stale entry.
EXCLUDED = {
    "http/oauth2_user": "Python has no oauth2_user auth type.",
    "http/oauth2_user_code": "Python has no oauth2_user auth type.",
}

# Seeds Python accepts and Dart rejects on purpose. `check` fails when Dart
# starts accepting one of them.
DART_REJECTS = {
    "websocket/zero_timeout": "Python parses websocket timeout 0, then asyncio.timeout(0) fails every call; "
    "Dart rejects the template instead.",
}

MISSING = "<missing>"

# Changes Dart's round trip may make: (JSON path pattern, value Python wrote,
# value Python reads back from Dart, why that is the same configuration).
EXPECTED_DIFFS = [
    (r"\.headers$", None, {}, "Dart writes absent static headers as {}; Python treats null and {} alike."),
    (r"\.header_fields$", None, [], "Dart writes absent header_fields as []; Python treats null and [] alike."),
    (r"^\$\.load_variables_from$", None, [], "Dart writes no variable loaders as []; Python treats null and [] alike."),
    (r"^\$\.timeout$", 0, 60000,
     "Dart reads streamable_http timeout 0 as the 60 s default and writes that; Python does the same at call time."),
    (r"\.mcpServers\.\w+\.transport$", MISSING, "stdio", "Dart writes the transport it inferred from `command`."),
    (r"\.mcpServers\.\w+\.env$", MISSING, {},
     "Dart writes absent stdio MCP env as {}; the mcp package merges both into the default environment."),
    (r"\.mcpServers\.\w+\.timeout$", MISSING, 30,
     "Dart writes its (and TypeScript's) 30 s MCP timeout. Python leaves the default to mcp_use: 5 s for HTTP servers."),
    (r"\.mcpServers\.\w+\.headers$", MISSING, {}, "Dart writes absent MCP server headers as {}."),
    (r"\.mcpServers\.\w+\.sse_read_timeout$", MISSING, 300,
     "Dart writes TypeScript's HTTP MCP server defaults; mcp_use reads the same 300 s default."),
    (r"\.mcpServers\.\w+\.terminate_on_close$", MISSING, True,
     "Dart writes TypeScript's HTTP MCP server defaults; mcp_use ignores the key."),
    (r"\.mcpServers\.\w+\.notification_stream_max_retries$", MISSING, 0,
     "Dart writes TypeScript's HTTP MCP server defaults; mcp_use ignores the key."),
]

SERIALIZERS = {
    "call_template": CallTemplateSerializer,
    "manual": UtcpManualSerializer,
    "config": UtcpClientConfigSerializer,
}
SEED_SECTIONS = {"call_templates": "call_template", "manuals": "manual", "configs": "config"}


def round_trip(kind, document):
    serializer = SERIALIZERS[kind]()
    return json.loads(json.dumps(serializer.to_dict(serializer.validate_dict(document))))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def same_value(a, b):
    # JSON has one number type: 1 and 1.0 are equal, true and 1 are not.
    return a == b and isinstance(a, bool) == isinstance(b, bool)


def diff(expected, actual, path="$"):
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(expected.keys() | actual.keys()):
            yield from diff(expected.get(key, MISSING), actual.get(key, MISSING), f"{path}.{key}")
    elif isinstance(expected, list) and isinstance(actual, list) and len(expected) == len(actual):
        for i, (e, a) in enumerate(zip(expected, actual)):
            yield from diff(e, a, f"{path}[{i}]")
    elif not same_value(expected, actual):
        yield path, expected, actual


def expected_diff(path, before, after):
    for pattern, old, new, _ in EXPECTED_DIFFS:
        if re.search(pattern, path) and same_value(old, before) and same_value(new, after):
            return pattern
    return None


def first_line(error):
    return str(error).strip().splitlines()[-1][:300]


def serialize(seeds_path):
    seeds = load(seeds_path)
    documents, failures = [], []
    for section, kind in SEED_SECTIONS.items():
        for seed_id, seed in seeds[section].items():
            try:
                serialized = round_trip(kind, seed)
            except Exception as error:  # noqa: BLE001 - any SDK rejection is a result
                if seed_id not in EXCLUDED:
                    failures.append(f"{seed_id}: Python rejects the seed: {first_line(error)}")
                continue
            if seed_id in EXCLUDED:
                failures.append(f"{seed_id}: excluded ({EXCLUDED[seed_id]}) but Python now parses it")
                continue
            documents.append({"id": seed_id, "kind": kind, "json": serialized})
    for seed_id, reason in EXCLUDED.items():
        print(f"python: excluded {seed_id}: {reason}", file=sys.stderr)
    for seed_id, reason in DART_REJECTS.items():
        print(f"python: Dart rejects {seed_id}: {reason}", file=sys.stderr)
    json.dump(
        {"sdk": SDK, "versions": {d: version(d) for d in DISTRIBUTIONS}, "documents": documents},
        sys.stdout, indent=2, sort_keys=True,
    )
    return failures


def check(serialized_path, dart_path):
    originals = {d["id"]: d for d in load(serialized_path)["documents"]}
    dart = {d["id"]: d for d in load(dart_path)["documents"]}
    failures, used = [], set()
    for seed_id, original in originals.items():
        output = dart.get(seed_id)
        if seed_id in DART_REJECTS:
            if output is not None and "error" not in output:
                failures.append(f"{seed_id}: Dart should reject it ({DART_REJECTS[seed_id]}) but parses it")
            continue
        if output is None or "error" in output:
            failures.append(f"{seed_id}: Dart failed: {output and output['error']}")
            continue
        try:
            again = round_trip(original["kind"], output["json"])
        except Exception as error:  # noqa: BLE001
            failures.append(f"{seed_id}: Python rejects Dart's output: {first_line(error)}")
            continue
        for path, before, after in diff(original["json"], again):
            pattern = expected_diff(path, before, after)
            if pattern is None:
                failures.append(f"{seed_id}: {path} changed: {json.dumps(before)} -> {json.dumps(after)}")
            used.add(pattern)
    for pattern, _, _, reason in EXPECTED_DIFFS:
        if pattern not in used:
            failures.append(f"expected diff {pattern} ({reason}) no longer occurs; remove it")
    print(f"python: checked {len(originals)} documents from {serialized_path}", file=sys.stderr)
    return failures


def accept(dart_path):
    failures, checked = [], 0
    for output in load(dart_path)["documents"]:
        if output["id"] in EXCLUDED or "error" in output:
            continue
        checked += 1
        try:
            round_trip(output["kind"], output["json"])
        except Exception as error:  # noqa: BLE001
            failures.append(f"{output['id']}: Python rejects Dart's output: {first_line(error)}")
    print(f"python: accepted {checked} documents from {dart_path}", file=sys.stderr)
    return failures


def main(argv):
    ensure_plugins_initialized()
    commands = {"serialize": (serialize, 1), "check": (check, 2), "accept": (accept, 1)}
    if len(argv) < 2 or argv[1] not in commands or len(argv) - 2 != commands[argv[1]][1]:
        print(__doc__, file=sys.stderr)
        return 2
    command, _ = commands[argv[1]]
    failures = command(*argv[2:])
    for failure in failures:
        print(f"python: FAIL {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
