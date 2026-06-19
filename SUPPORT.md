# Support

Use GitHub Discussions for setup questions and GitHub Issues for reproducible
bugs.

Before reporting a bug, run:

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager overview
```

Attach the output only after removing public IPs, domains, usernames and
credentials. Never attach a sysupgrade backup or files from:

```text
/etc/ikev2-manager/
/etc/swanctl/private/
```

Unsupported firmware may still be useful for investigation, but support is
best-effort until that platform appears in `docs/COMPATIBILITY.md`.
