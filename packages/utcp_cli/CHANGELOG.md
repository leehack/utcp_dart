## Unreleased

- Initial release: `cli` call template and protocol with multi-step commands, injection-safe argument placeholders, `$CMD_<i>_OUTPUT` references, `env_vars`, `inherit_env_vars` and `working_dir`.
- Discovery from command output, JSON output decoding, and process-tree cleanup on timeout, cancellation and `close()`.
