# Domain-list sources

IKEv2 Manager builds the active IPv4 domain policy from two independent
sources:

1. domains entered manually by the router administrator;
2. optional service lists selected in LuCI.

## Project-maintained lists

Small lists under `luci-ikev2-domains/local-services/` are maintained in this
repository and shipped in the package. They are used without network access
and are covered by the project's MIT License.

## Optional `itdoginfo/allow-domains` integration

For services not maintained locally, the router can retrieve lists from:

- catalog:
  `https://api.github.com/repos/itdoginfo/allow-domains/contents/Services`
- content:
  `https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Services`

The integration is optional. Merely installing the package does not download
external lists. A download occurs after the administrator selects an external
service and applies the domain policy.

As of June 19, 2026, `itdoginfo/allow-domains` does not publish a license file.
The external list contents are therefore not redistributed in this repository
or in its IPK artifacts, and they are not covered by this project's MIT
License. Attribution does not replace permission from the copyright holder.
Users should evaluate the upstream terms before enabling this integration.

## Update and failure behavior

`ikev2-domains-community` performs the following steps:

1. refreshes the service catalog periodically from the GitHub API;
2. downloads each selected service list over HTTPS;
3. accepts only normalized domain-name records;
4. writes a successful download into the persistent local cache;
5. falls back to the cached copy if the upstream request fails;
6. merges manual and selected service domains in a temporary directory;
7. atomically replaces the active list only after every selected service is
   available.

If a selected service cannot be downloaded and has no cached copy, the update
fails and the previous active list remains untouched.

## Security and reliability limits

The integration protects availability better than integrity:

- upstream outages are covered by the persistent cache;
- malformed records and empty selected lists are rejected;
- catalog and service downloads have explicit size limits;
- the active policy is replaced atomically;
- upstream content follows the mutable `main` branch;
- there is no upstream signature or checksum;
- a compromised upstream account could publish syntactically valid but
  unwanted domains;
- unauthenticated GitHub API rate limits may delay catalog refreshes.

For a high-assurance deployment, disable external services and use only manual
or project-maintained lists, or override `IKEV2_CATALOG_URL` and
`IKEV2_RAW_BASE` with a reviewed, version-pinned mirror.
