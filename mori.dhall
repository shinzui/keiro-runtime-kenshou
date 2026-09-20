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
    , dependencies = [ "shinzui/keiro" ]
    , dependencyRefs =
      [ Schema.MoriRef::{ namespace = "shinzui", name = "keiro" } ]
    }
