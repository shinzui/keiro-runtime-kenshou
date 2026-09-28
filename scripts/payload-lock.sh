#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( $1 != released && $1 != head ) ]]; then
  echo "usage: scripts/payload-lock.sh released|head" >&2
  exit 2
fi

cohort_name=$1
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
descriptor_file="$repo_root/cohort/$cohort_name.json"
lock_dir="$repo_root/nix/cohort-locks"
lock_file="$lock_dir/$cohort_name.lock.json"
mkdir -p "$lock_dir"

jq -e --arg name "$cohort_name" '
  .schema == "kenshou.cohort/v1" and .name == $name and
  (.components | type == "array" and length > 0)
' "$descriptor_file" >/dev/null

descriptor_sha=$(nix hash file --type sha256 --base16 "$descriptor_file")
entries_file=$(mktemp)
lock_tmp=$(mktemp "$lock_dir/.payload-lock.XXXXXX")
trap 'rm -f -- "$entries_file" "$lock_tmp"' EXIT

declare -A git_hashes
while IFS= read -r package_json; do
  package_name=$(jq -r .name <<<"$package_json")
  package_version=$(jq -r .version <<<"$package_json")
  source_kind=$(jq -r .source.type <<<"$package_json")

  case "$source_kind" in
    hackage)
      tarball_url="https://hackage.haskell.org/package/$package_name-$package_version/$package_name-$package_version.tar.gz"
      echo "locking $package_name-$package_version from Hackage" >&2
      flat_nix32=$(nix-prefetch-url --type sha256 "$tarball_url")
      unpacked_nix32=$(nix-prefetch-url --type sha256 --unpack "$tarball_url")
      tarball_sha=$(nix hash convert --hash-algo sha256 --from nix32 --to base16 "$flat_nix32")
      unpacked_sha=$(nix hash convert --hash-algo sha256 --from nix32 --to sri "$unpacked_nix32")
      jq -nc \
        --arg name "$package_name" --arg version "$package_version" \
        --arg sha256 "$unpacked_sha" --arg tarballSha256 "$tarball_sha" \
        '{name: $name, lock: {source: "hackage", version: $version, sha256: $sha256, tarballSha256: $tarballSha256}}' \
        >>"$entries_file"
      ;;
    git)
      location=$(jq -r .source.location <<<"$package_json")
      revision=$(jq -r .source.rev <<<"$package_json")
      subdir=$(jq -r '.subdir // ""' <<<"$package_json")
      if [[ ! $location =~ ^https://github\.com/([^/]+)/([^/]+)\.git$ ]]; then
        echo "unsupported git location for $package_name: $location" >&2
        exit 2
      fi
      owner=${BASH_REMATCH[1]}
      repository=${BASH_REMATCH[2]}
      git_key="$owner/$repository@$revision"
      if [[ ! -v git_hashes[$git_key] ]]; then
        echo "locking $git_key from GitHub" >&2
        git_hashes[$git_key]=$(nix flake prefetch --json "github:$owner/$repository/$revision" | jq -er .hash)
      fi
      jq -nc \
        --arg name "$package_name" --arg version "$package_version" \
        --arg owner "$owner" --arg repo "$repository" --arg rev "$revision" \
        --arg subdir "$subdir" --arg hash "${git_hashes[$git_key]}" \
        '{name: $name, lock: {source: "git", version: $version, owner: $owner, repo: $repo, rev: $rev, subdir: $subdir, hash: $hash}}' \
        >>"$entries_file"
      ;;
    *)
      echo "unsupported source for $package_name: $source_kind" >&2
      exit 2
      ;;
  esac
done < <(jq -c '.components[] as $component | $component.packages[] | . + {source: $component.source}' "$descriptor_file")

jq -S -s --arg cohort "$cohort_name" --arg descriptorSha256 "$descriptor_sha" '
  {
    schema: "kenshou.cohort-nix-lock/v1",
    cohort: $cohort,
    descriptorSha256: $descriptorSha256,
    packages: (map({(.name): .lock}) | add)
  }
' "$entries_file" >"$lock_tmp"

if [[ ! -f $lock_file ]] || ! cmp -s "$lock_tmp" "$lock_file"; then
  mv "$lock_tmp" "$lock_file"
fi
echo "$lock_file"
