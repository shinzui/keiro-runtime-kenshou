--| Shared ADR profile. Bump the tag and semantic hash together when upgrading.
--
-- Loading this v0.18.0 descriptor requires `okf` 0.9.0.0 or later, whose schema
-- adds optional profile and type `guidance`. The shared profile leaves guidance
-- absent; v0.18.0 changes no rule this bundle is validated against.
--
-- This descriptor is a plain pinned import. It carries no override, because
-- v0.8.0 folded the one this file used to layer into the upstream profile:
-- `supersedes`, `supersededBy`, and `originatingPlan` are `optional` as
-- shipped, so the local reclassification became a no-op. If you are upgrading a
-- descriptor installed at v0.7.0, delete the `//` override it carries; deleting
-- it changes nothing about which documents pass.
--
-- The profile targets Open Knowledge Format v0.2. Every concept must carry a
-- `generated` mapping whose `by` is an OKF §7 actor (`human:<id>`,
-- `process:<id>`, or `<producer>/<version>`), and the bundle root must declare
-- `okf_version: "0.2"` -- write it with
-- `okf index docs/adr --write --okf-version 0.2`. The superseded v0.1
-- `timestamp` key is `optional`: keep it if you have it, its format is still
-- checked, and its absence is never reported.
--
-- The integrity hash below is the semantic hash of the v0.18.0 package. When bumping to a future release, change the tag, delete the hash
-- line, and re-run:
--
--     dhall freeze blueprints/adopt-architecture-decisions/files/architecture-decisions-profile.dhall
--
-- Never hand-write a `sha256:` value, and never delete a hash from a frozen
-- import to make it resolve.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.18.0/package.dhall
        sha256:7d3a4a22be12fd0e697d6012ed1eb2efe4cb5dc4700d08fd49aa5e4c0e523df8

in  Profiles.documentation.architectureDecisions
