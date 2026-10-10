-- Shared contract: mori://shinzui/okf-profiles/profiles/user-documentation
-- Export documentation.userDocumentation from the published v0.20.0 package.
-- Upgrade the release and its semantic hash together with `dhall freeze`.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall
        sha256:079a5b3679dccafd2070535b3d59a0ffdf28e20bf9cacfe095dca96c8012879a

in  Profiles.documentation.userDocumentation
