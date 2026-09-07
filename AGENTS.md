# Repository instructions

## Public information only

This is a public repository. Do not commit credentials, private hostnames,
personal account names or paths, internal addresses/domains, SSH keys, real
deployment inventories, or private audit records. This applies to source,
documentation, examples, tests, generated files, and commit metadata.

Discover deployment-specific values at runtime or read them from the existing
local configuration. Use generic examples and synthetic test data. Standard
platform paths and documented public service endpoints are appropriate; private
machine details are not. Keep local deployment/audit records outside the Git
working tree and inspect staged files before publishing.

If honoring this requirement would require a radical behavior or configuration
change, explain the concrete issue to the maintainer before making that change.

## Compatibility and documentation

Preserve the existing configuration format, setup flow, override precedence,
and each platform's installed configuration paths and permissions. Updates must
preserve local configuration. The proposed v2.0 design requires explicit root
`--update` to install a release; automatic checks only report availability.

Keep user documentation in `README.md`, completed changes in `CHANGELOG.md`,
and planned features and bug fixes in `TODO.md`. Do not label planned work as
implemented or released. Keep useful implementation comments in the script.

Develop as a normal user. Use isolated files and mocked network responses for
automated checks; do not use live notification credentials in tests or send
Pushover messages as a side effect of an audit.
