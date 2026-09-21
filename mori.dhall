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
      ]
    }
