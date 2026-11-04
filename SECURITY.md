# Security policy

## Reporting

Do not open a public issue for a vulnerability that could expose a host,
credential, deployment, or user data. Report it privately to the repository
maintainer, including:

- affected script and version/commit;
- platform and command line;
- whether the issue is reachable without root, and with which preconditions;
- a minimal reproduction that does not modify a real system.

## Scope

The scripts perform privileged administration. They are intended to be
reviewed before execution and are not a sandbox. Downloads are verified when
the upstream project publishes a checksum or signature; where it does not, the
documentation states the remaining trust boundary.

## Supported versions

`VERSION` identifies the installed runtime metadata. Only the current `main`
branch and the latest tagged release are supported. There is no long-term
support branch.
