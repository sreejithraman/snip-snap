# 0013: Limit built-in sync to the project CloudKit container

Official Snip Snap builds offer optional sync through a CloudKit container owned by the project maintainers and the user's private iCloud database. Forks may remain local-only or use a container that the fork owner configures. The project does not provide shared lists, collaboration, a shared community backend, or self-hosted sync because those options would add permissions, invitations, ownership, accounts, server operations, and another trust model without a current product need.

## Consequences

Normal contributor builds and tests must work without the maintainer's Apple team, signing keys, paid services, or iCloud account. Production container changes and schema promotion remain maintainer release tasks.
