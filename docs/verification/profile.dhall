--| Local profile for the kenshou verification evidence bundle (docs/verification).
--
-- Three concept types: `Attested Computation` (a definition, handle VC-N),
-- `Verification Run` (an immutable event: one run, or one comparison of runs) and
-- `Attestation` (an immutable event: what a deterministic verifier concluded).
-- Records carry identity, provenance, outcome and digest-pinned links to data in
-- durable object storage. They never carry a measurement: `allowUnknownFields =
-- False` is what turns a stray `p99Millis:` into a validation failure.
--
-- The file has three parts so that the shared profile can later be lifted into
-- okf-profiles without touching the rest: (1) vocabularies that belong to the
-- keiro runtime and stay here, (2) `shared`, the part that is lifted, and (3) the
-- overlay that closes the runtime-specific vocabularies again.
--
-- What no descriptor can express is checked by `kenshou evidence check`.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.18.0/package.dhall
        sha256:7d3a4a22be12fd0e697d6012ed1eb2efe4cb5dc4700d08fd49aa5e4c0e523df8

let Profile = Profiles.Profile

let TypeRule = Profiles.TypeRule

let FrontmatterRules = Profiles.FrontmatterRules

let FieldRule = Profiles.FieldRule

let NestedRules = Profiles.NestedRules

let NestedFieldRule = Profiles.NestedFieldRule

let HandleReferenceRule = Profiles.HandleReferenceRule

let PathReferenceRule = Profiles.PathReferenceRule

let Cardinality = Profiles.Cardinality

let FieldFormat = Profiles.FieldFormat

let v02 = Profiles.v02

let runtimeSpecific =
      { layers =
        [ "selftest", "pgmq", "kiroku", "shibuya", "kafka", "keiro", "runtime" ]
      , tiers = [ "smoke", "standard", "extended", "soak" ]
      }

let kinds = [ "correctness", "concurrency", "soak", "benchmark" ]

let placements = [ "local", "cell" ]

let outcomes =
      [ "passed"
      , "failed"
      , "errored"
      , "inconclusive"
      , "infrastructure-failure"
      ]

let comparisonVerdicts =
      [ "pass", "regression", "inconclusive", "infrastructure-failure" ]

let purposes = [ "nightly", "release", "baseline", "investigation" ]

let dataKinds =
      [ "run-spec"
      , "run-result"
      , "manifest"
      , "cell-manifest"
      , "samples"
      , "series"
      , "verdicts"
      , "diagnosis"
      , "logs"
      , "comparison"
      ]

let checkNames =
      [ "digests-match"
      , "revisions-resolve"
      , "cohort-matches-plan"
      , "verdict-recomputed"
      , "environment-captured"
      , "clean-worktree"
      ]

let scalar =
      \(name : Text) ->
      \(description : Text) ->
        FieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.Scalar
        }

let enum =
      \(name : Text) ->
      \(description : Text) ->
      \(allowedValues : List Text) ->
        scalar name description // { allowedValues }

let formatted =
      \(name : Text) ->
      \(description : Text) ->
      \(format : FieldFormat) ->
        scalar name description // { format = Some format }

let list =
      \(name : Text) ->
      \(description : Text) ->
        FieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.List
        }

let nScalar =
      \(name : Text) ->
      \(description : Text) ->
        NestedFieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.Scalar
        }

let nEnum =
      \(name : Text) ->
      \(description : Text) ->
      \(allowedValues : List Text) ->
        nScalar name description // { allowedValues }

let nFormatted =
      \(name : Text) ->
      \(description : Text) ->
      \(format : FieldFormat) ->
        nScalar name description // { format = Some format }

let nPaths =
      \(name : Text) ->
      \(description : Text) ->
        NestedFieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.List
        , path = Some PathReferenceRule::{=}
        }

let nPath =
      \(name : Text) ->
      \(description : Text) ->
        NestedFieldRule::{
        , field = name
        , description = Some description
        , path = Some PathReferenceRule::{=}
        }

let bundlePath =
      \(name : Text) ->
      \(description : Text) ->
        scalar name description // { path = Some PathReferenceRule::{=} }

let computationRef = Some HandleReferenceRule::{ localPrefix = "VC" }

let isRun = Some { field = "recordKind", hasValue = [ "run" ] }

let isComparison = Some { field = "recordKind", hasValue = [ "comparison" ] }

let nameValue =
      NestedRules::{
      , required =
        [ nScalar "name" "Name, as the harness spells it."
        , nScalar "value" "Value the run used."
        ]
      }

let attestedComputation =
      TypeRule::{
      , type = "Attested Computation"
      , description = Some
          "How one outcome, verdict or figure is computed from raw run data, and how a deterministic verifier re-checks it."
      , pathPattern = Some "computations/*"
      , idPrefix = Some "VC"
      , frontmatter = FrontmatterRules::{
        , required =
          [ formatted
              "computationId"
              "Bundle-scoped stable VC-N handle."
              (FieldFormat.DocumentHandle "VC")
          , scalar "runtime" "How the computation is run: `kenshou`."
          , scalar
              "algorithm"
              "Identifier the harness writes into its documents."
          , formatted
              "algorithmVersion"
              "A change that can alter a result takes a new VC handle."
              FieldFormat.NonNegativeInteger
          , enum
              "produces"
              "What the computation yields."
              [ "outcome", "verdict", "diagnosis", "comparison", "summary" ]
          ,     list "inputs" "Data-link kinds the computation reads."
            //  { allowedValues = dataKinds }
          , scalar "implementation" "Haskell module implementing the algorithm."
          ,     list "parameters" "Typed named holes; empty when it takes none."
            //  { elementFields = Some NestedRules::{
                  , required =
                    [ nScalar "name" "The name the computation binds."
                    , nScalar "type" "What kind of value it takes."
                    ]
                  , optional =
                    [ nFormatted
                        "required"
                        "Whether a caller must supply it."
                        FieldFormat.Boolean
                    ]
                  }
                }
          , FieldRule::{
            , field = "executor"
            , description = Some "How a run is performed and what it returns."
            , objectFields = Some NestedRules::{
              , required =
                [ nPath "resource" "Run instructions: a non-Markdown file here."
                ,     nScalar "receipt" "Run-directory documents a run returns."
                  //  { cardinality = Cardinality.List }
                ]
              }
            }
          , FieldRule::{
            , field = "attester"
            , description = Some "Deterministic code that re-checks a run."
            , objectFields = Some NestedRules::{
              , required =
                [ nPath "resource" "The verifier: a non-Markdown file here." ]
              }
            }
          ]
        , optional =
          [ v02.status
          , v02.staleAfter
          ,     list "appliesTo" "Evidence kinds whose runs may name it."
            //  { allowedValues = kinds }
          , bundlePath "computation" "The computation file, when not inline."
          ,     scalar "supersedes" "The definition this one replaces."
            //  { reference = computationRef }
          ]
        }
      }

let componentMembers =
      NestedRules::{
      , required =
        [ nFormatted
            "project"
            "Mori URI of the owning project."
            (FieldFormat.UriWithScheme "mori")
        , nScalar "package" "Cabal package name."
        , nScalar "version" "Exact resolved version."
        , nEnum "source" "Where the solver took it from." [ "hackage", "git" ]
        ,     nScalar "revision" "Full 40-character commit."
          //  { when = Some { field = "source", hasValue = [ "git" ] } }
        ]
      }

let environmentMembers =
      NestedRules::{
      , required =
        [ nScalar "os" "Operating system."
        , nScalar "arch" "CPU architecture."
        , nScalar "cpuModel" "CPU model string."
        , nFormatted "cores" "Logical cores." FieldFormat.NonNegativeInteger
        , nFormatted
            "memoryBytes"
            "Physical memory."
            FieldFormat.NonNegativeInteger
        , nScalar "ghc" "Compiler that built the harness."
        , nScalar "postgres" "PostgreSQL server version."
        ]
      , optional =
        [ nScalar "kernel" "Kernel release."
        , nScalar "machineType" "Cloud machine type of the driver."
        , nScalar "cell" "Name of the leased cell."
        , nScalar "cellRun" "The cell's own identifier for the leased run."
        , nScalar "zone" "Cloud zone."
        , nScalar "kafka" "Broker version, when a broker took part."
        ]
      }

let dataMembers =
      NestedRules::{
      , required =
        [ nEnum "kind" "What the object is." dataKinds
        , nFormatted
            "uri"
            "Where the object lives in durable storage."
            (FieldFormat.UriWithScheme "gs")
        , nScalar "digest" "Lowercase 64-hex SHA-256 of the object."
        , nScalar "mediaType" "IANA media type."
        , nFormatted "bytes" "Object size." FieldFormat.NonNegativeInteger
        ]
      }

let comparisonMembers =
      NestedRules::{
      , required =
        [ nEnum "verdict" "What the comparison concluded." comparisonVerdicts
        , nEnum
            "factor"
            "What differs between the arms."
            [ "cohort", "harness", "dimension", "knob" ]
        , nScalar "baselineValue" "The factor's value on the baseline arm."
        , nScalar "candidateValue" "The factor's value on the candidate arm."
        , nEnum
            "design"
            "How the arms were interleaved."
            [ "abba", "baab", "sequential" ]
        , nPaths "baselineRuns" "Recorded runs of the baseline arm."
        , nPaths "candidateRuns" "Recorded runs of the candidate arm."
        ]
      , optional =
        [ nScalar "factorName" "Which dimension, knob or package differs." ]
      }

let verificationRun =
      TypeRule::{
      , type = "Verification Run"
      , description = Some
          "One recorded run, or one recorded comparison of runs: what ran, against what, where, with which outcome, and where the data is."
      , pathPattern = Some "runs/*/*/*/*"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "runId" "UUIDv7 of the record. Equals the file name."
          , enum
              "recordKind"
              "One run, or a comparison of runs."
              [ "run", "comparison" ]
          , enum "purpose" "Why this was recorded." purposes
          , scalar "scenario" "Scenario identifier: layer/component/kind/name."
          , scalar "layer" "Runtime layer the scenario isolates."
          , scalar "component" "Component inside the layer."
          , enum "kind" "Kind of evidence." kinds
          , scalar "tier" "Cost tier."
          , enum "placement" "Where it ran." placements
          , enum "outcome" "What came of it." outcomes
          , formatted "startedAt" "UTC start." FieldFormat.Rfc3339Utc
          , formatted "finishedAt" "UTC finish." FieldFormat.Rfc3339Utc
          , formatted
              "subject"
              "Mori URI of the most specific runtime artifact under test."
              (FieldFormat.UriWithScheme "mori")
          , enum "subjectKind" "What `subject` names." [ "project", "package" ]
          , scalar "harnessRevision" "Full 40-character commit of the harness."
          , formatted
              "harnessDirty"
              "Whether the harness was built from a modified tree."
              FieldFormat.Boolean
          ,     list "computations" "Definitions that produced the outcome."
            //  { reference = computationRef }
          ,     list "data" "Digest-pinned links to the data."
            //  { elementFields = Some dataMembers, uniqueBy = Some "uri" }
          ,     scalar "cohort" "Name of the cohort the build linked."
            //  { when = isRun }
          ,     scalar "solverPlanHash" "Hash of the resolved solver plan."
            //  { when = isRun }
          ,     list "components" "Every runtime package the build linked."
            //  { elementFields = Some componentMembers
                , uniqueBy = Some "package"
                , when = isRun
                }
          , FieldRule::{
            , field = "environment"
            , description = Some "Flat excerpt of the environment fingerprint."
            , objectFields = Some environmentMembers
            , when = isRun
            }
          ,     formatted
                  "seed"
                  "Seed of every random choice."
                  FieldFormat.NonNegativeInteger
            //  { when = isRun }
          ,     scalar
                  "compatibilityKey"
                  "64-hex digest of what must match for two runs to be comparable."
            //  { when = isRun }
          , FieldRule::{
            , field = "comparison"
            , description = Some "The arms and the verdict."
            , objectFields = Some comparisonMembers
            , when = isComparison
            }
          ]
        , optional =
          [     list "knobs" "Knob values the run used."
            //  { elementFields = Some nameValue, uniqueBy = Some "name" }
          ,     list "dimensions" "Dimension values the run used."
            //  { elementFields = Some nameValue, uniqueBy = Some "name" }
          ,     list "knownDefects" "Known-defect references of the scenario."
            //  { format = Some FieldFormat.Uri }
          ,     list "produced" "Mori URIs of reports this run caused."
            //  { format = Some (FieldFormat.UriWithScheme "mori") }
          , bundlePath
              "previousRun"
              "Latest earlier record of the same scenario and compatibility key."
          ]
        }
      }

let attestation =
      TypeRule::{
      , type = "Attestation"
      , description = Some
          "A deterministic verifier fetched a record's data, re-checked it, and this is what it concluded."
      , pathPattern = Some "attestations/*/*/*"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "attestationId" "UUIDv7. Equals the file name."
          , bundlePath "run" "The record attested."
          , formatted
              "attester"
              "The verifier, as an OKF actor."
              FieldFormat.Actor
          , scalar
              "attesterRevision"
              "Full 40-character commit of the verifier."
          , formatted "attestedAt" "UTC completion time." FieldFormat.Rfc3339Utc
          , enum
              "verdict"
              "What the verifier concluded."
              [ "confirmed", "refuted", "incomplete" ]
          ,     list "checks" "Every check, and what it found."
            //  { elementFields = Some NestedRules::{
                  , required =
                    [ nEnum "name" "Which check." checkNames
                    , nEnum
                        "result"
                        "What it found."
                        [ "passed", "failed", "skipped" ]
                    ]
                  , optional = [ nScalar "detail" "One line saying why." ]
                  }
                , uniqueBy = Some "name"
                }
          , list
              "dataDigests"
              "64-hex SHA-256 of every object fetched and matched."
          ]
        , optional =
          [ FieldRule::{
            , field = "exception"
            , description = Some "A human's acceptance of an anomaly."
            , objectFields = Some NestedRules::{
              , required =
                [ nFormatted
                    "authority"
                    "The human who accepted it."
                    FieldFormat.HumanActor
                , nScalar "reason" "Why the anomaly is acceptable."
                ]
              }
            }
          ]
        }
      }

let shared =
      Profile::{
      , name = "verification-evidence"
      , description = Some
          "Evidence about a runtime: definitions of how verdicts are computed, immutable records of runs that link to their data by digest, and attestations that a deterministic verifier re-checked that data."
      , okfVersion = "0.2"
      , requireBundleVersion = Some "0.2"
      , allowUnknownTypes = False
      , allowUnknownFields = False
      , idField = Some "computationId"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "type" "One of the three concept types."
          , scalar "title" "What this record is, in one line."
          , scalar "description" "One sentence a reader can evaluate alone."
          , v02.generated
          ]
        , optional = [ v02.verified ]
        }
      , types = [ attestedComputation, verificationRun, attestation ]
      }

in      shared
    //  { frontmatter =
                shared.frontmatter
            //  { optional =
                      shared.frontmatter.optional
                    # [ enum
                          "layer"
                          "Runtime layer the scenario isolates."
                          runtimeSpecific.layers
                      , enum "tier" "Cost tier." runtimeSpecific.tiers
                      ]
                }
        }
