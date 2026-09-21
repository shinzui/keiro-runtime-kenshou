# Kenshou JSON schemas

These JSON Schema 2020-12 documents describe the stable, versioned interfaces
owned by `kenshou-core`. File names retain the document version permanently. A
breaking format change adds a sibling `v2` schema and codec; it does not rewrite
the meaning of a published `v1` document.

| Document | Schema identifier | Owner |
| --- | --- | --- |
| Run specification | `kenshou.run-spec/v1` | `Kenshou.Core.RunSpec` |
| Run result | `kenshou.run-result/v1` | `Kenshou.Core.RunResult` |
| Artifact manifest | `kenshou.artifact-manifest/v1` | `Kenshou.Core.Manifest` |
| Scenario list | `kenshou.scenario-list/v1` | `Kenshou.Core.Bundle` |
| Worker initialization | `kenshou.worker-init/v1` | `Kenshou.Core.Role` |
| Worker messages | `kenshou.worker-message/v1` | `Kenshou.Core.Role` |

Run `just schemas-check` to validate the checked-in goldens and fresh CLI
documents.
