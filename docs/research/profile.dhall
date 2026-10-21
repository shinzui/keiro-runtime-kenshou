-- OKF profile descriptor written by `okf profile init`.
-- 
-- Profile: documentation.researchDocuments
-- Source:  https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall
-- 
-- Existing hashes are preserved and unhashed remote value imports are frozen.
-- Local and environment inputs remain live; this is not a portable snapshot.
-- To update remote imports, remove their hashes and run `dhall freeze profile.dhall`.
-- Never hand-write a sha256 value.
let registry =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall
        sha256:079a5b3679dccafd2070535b3d59a0ffdf28e20bf9cacfe095dca96c8012879a

in  registry.documentation.researchDocuments
