let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/package.dhall
        sha256:dcb19e2312e790bad14e622cc98a1281cd2298c5b564a2f0d0534d3c718d8803

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "keiro-runtime-kenshou"
      , namespace = "shinzui"
      , stableId = Some "project_01m2zvxe8teq9ae1nsbzrv4s4h"
      , type = Schema.PackageType.Application
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "Verification evidence for the Keiro runtime: executable correctness properties, concurrency and fault-injection suites, and benchmarks with retained baselines for cross-release regression detection."
      , domains =
        [ "EventSourcing", "Workflow", "Testing", "Benchmarking" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{
        , name = "keiro-runtime-kenshou"
        , github = Some "shinzui/keiro-runtime-kenshou"
        }
      ]
    , packages =
      [ Schema.Package::{
        , name = "kenshou-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./kenshou-core"
        , description = Some
            "Cohort identity and the shared kernel for Keiro runtime verification"
        }
      , Schema.Package::{
        , name = "kenshou-cli"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "./kenshou-cli"
        , description = Some
            "Operator interface and aggregate runtime verification executable"
        }
      , Schema.Package::{
        , name = "kenshou-remote"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./kenshou-remote"
        , description = Some
            "Leased verification cell client and immutable result verification"
        }
      , Schema.Package::{
        , name = "kenshou-evidence"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./kenshou-evidence"
        , description = Some
            "Historic verification records and durable evidence storage"
        }
      ]
    , dependencies =
      [ "shinzui/keiro"
      , "shinzui/keiki"
      , "shinzui/kiroku"
      , "shinzui/shibuya"
      , "shinzui/shibuya-pgmq-adapter"
      , "shinzui/shibuya-kafka-adapter"
      , "shinzui/kafka-effectful"
      , "shinzui/hw-kafka-streamly"
      , "shinzui/hw-kafka-client"
      , "haskell-works/hw-kafka-client"
      , "shinzui/pgmq-hs"
      , "shinzui/pg-migrate"
      , "shinzui/ephemeral-pg"
      , "iand675/hs-opentelemetry"
      , "shinzui/okf"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{ namespace = "shinzui", name = "keiro" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "keiki" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "kiroku" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "shibuya" }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya-pgmq-adapter"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya-kafka-adapter"
        }
      , Schema.MoriRef::{ namespace = "shinzui", name = "kafka-effectful" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "hw-kafka-streamly" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "hw-kafka-client" }
      , Schema.MoriRef::{
        , namespace = "haskell-works"
        , name = "hw-kafka-client"
        }
      , Schema.MoriRef::{ namespace = "shinzui", name = "pgmq-hs" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "pg-migrate" }
      , Schema.MoriRef::{ namespace = "shinzui", name = "ephemeral-pg" }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        }
      , Schema.MoriRef::{ namespace = "shinzui", name = "okf" }
      ]
    , docs =
      [ Schema.DocRef::{
        , key = "masterplan"
        , kind = Schema.DocKind.Spec
        , audience = Schema.DocAudience.Module
        , description = Some
            "Initiative plan for the extensive Keiro runtime verification suite"
        , location =
            Schema.DocLocation.LocalFile
              "./docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Durable architecture decisions"
        }
      , Schema.OkfBundle::{
        , name = "verification"
        , path = "docs/verification"
        , profile = Some "docs/verification/profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "shinzui/okf-profiles"
                , publisherRef = Some Schema.MoriRef::{
                  , namespace = "shinzui"
                  , name = "okf-profiles"
                  }
                , export = Some "assurance.verificationEvidence"
                , version = Some "v0.19.0"
                , pin = Some "sha256:85176d78369b6d73c9f13c30277903b629d6bf048a4c7d71fc26e68b99c3eaa6"
                , derived = True
                }
            )
        , okfVersion = "0.2"
        , description = Some
            "Immutable verification run and attestation records with versioned computation definitions"
        }
      , Schema.OkfBundle::{
        , name = "terminology"
        , path = "docs/terminology"
        , profile = Some "mori/terminology-profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "shinzui/okf-profiles"
                , publisherRef = Some Schema.MoriRef::{
                  , namespace = "shinzui"
                  , name = "okf-profiles"
                  }
                , export = Some "documentation.terminology"
                , version = Some "v0.19.0"
                , pin = Some "sha256:85176d78369b6d73c9f13c30277903b629d6bf048a4c7d71fc26e68b99c3eaa6"
                }
            )
        , okfVersion = "0.2"
        , description = Some "Controlled vocabulary for Kenshou verification"
        }
      , Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "mori/improvement-requests-profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "shinzui/okf-profiles"
                , publisherRef = Some Schema.MoriRef::{
                  , namespace = "shinzui"
                  , name = "okf-profiles"
                  }
                , export = Some "coordination.improvementRequests"
                , version = Some "v0.19.0"
                , pin = Some "sha256:85176d78369b6d73c9f13c30277903b629d6bf048a4c7d71fc26e68b99c3eaa6"
                }
            )
        , okfVersion = "0.2"
        , description = Some
            "Improvement requests for Kenshou's own harness and packaging"
        }
      ]
    }
