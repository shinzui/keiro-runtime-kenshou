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

let knobs =
      Profiles.FieldRule::{
      , field = "knobs"
      , cardinality = Profiles.Cardinality.List
      , uniqueBy = Some "name"
      , elementFields = Some Profiles.NestedRules::{
        , required =
          [ Profiles.NestedFieldRule::{
            , field = "name"
            , cardinality = Profiles.Cardinality.Scalar
            }
          ]
        , optional =
          [ Profiles.NestedFieldRule::{
            , field = "value"
            , cardinality = Profiles.Cardinality.Scalar
            }
          ]
        }
      }

let withoutFirst =
      \(rules : List Profiles.FieldRule.Type) ->
        let reversed =
              List/fold
                Profiles.FieldRule.Type
                rules
                (List Profiles.FieldRule.Type)
                ( \(rule : Profiles.FieldRule.Type) ->
                  \(acc : List Profiles.FieldRule.Type) ->
                    acc # [ rule ]
                )
                ([] : List Profiles.FieldRule.Type)

        in  ( List/fold
                Profiles.FieldRule.Type
                reversed
                { first : Bool, items : List Profiles.FieldRule.Type }
                ( \(rule : Profiles.FieldRule.Type) ->
                  \ ( state
                    : { first : Bool, items : List Profiles.FieldRule.Type }
                    ) ->
                    if    state.first
                    then  { first = False, items = state.items }
                    else  { first = False, items = state.items # [ rule ] }
                )
                { first = True, items = [] : List Profiles.FieldRule.Type }
            ).items

let adaptedTypes =
      ( List/fold
          Profiles.TypeRule.Type
          shared.types
          { first : Bool, second : Bool, items : List Profiles.TypeRule.Type }
          ( \(rule : Profiles.TypeRule.Type) ->
            \ ( state
              : { first : Bool
                , second : Bool
                , items : List Profiles.TypeRule.Type
                }
              ) ->
              if    state.first
              then  { first = False
                    , second = True
                    , items = [ rule ] # state.items
                    }
              else  if state.second
              then  { first = False
                    , second = False
                    , items =
                          [     rule
                            //  { frontmatter =
                                        rule.frontmatter
                                    //  { optional =
                                              withoutFirst
                                                rule.frontmatter.optional
                                            # [ knobs ]
                                        }
                                }
                          ]
                        # state.items
                    }
              else  { first = False
                    , second = False
                    , items = [ rule ] # state.items
                    }
          )
          { first = True
          , second = False
          , items = [] : List Profiles.TypeRule.Type
          }
      ).items

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
        , types = adaptedTypes
        }
