--| Descriptor for the verification evidence bundle: the shared profile, published by
-- mori://shinzui/okf-profiles/profiles/verification-evidence, with the two vocabularies
-- that name parts of the keiro runtime narrowed again for this repository.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.19.0/package.dhall
        sha256:85176d78369b6d73c9f13c30277903b629d6bf048a4c7d71fc26e68b99c3eaa6

let shared = Profiles.assurance.verificationEvidence

let closed =
      \(name : Text) ->
      \(values : List Text) ->
        Profiles.FieldRule::{
        , field = name
        , allowedValues = values
        , cardinality = Profiles.Cardinality.Scalar
        }

in      shared
    //  { frontmatter =
                shared.frontmatter
            //  { optional =
                      shared.frontmatter.optional
                    # [ closed
                          "layer"
                          [ "selftest"
                          , "pgmq"
                          , "kiroku"
                          , "shibuya"
                          , "kafka"
                          , "keiro"
                          , "runtime"
                          ]
                      , closed
                          "tier"
                          [ "smoke", "standard", "extended", "soak" ]
                      ]
                }
        }
