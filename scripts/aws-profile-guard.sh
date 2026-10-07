#!/usr/bin/env bash
# Guard for every script that talks to AWS. Sourced, never run.
#
# Two rules, and both exist because this machine has credentials for accounts that are
# not ours: a script never guesses which account to touch, and the profiles belonging to
# the frozen box and to the other tenant are never a deploy target. Widening this list is
# a deliberate edit, in a review, not a flag.

AWS_DENIED_PROFILE_PREFIXES=(godson regina)

# require_aws_profile <profile> [expected-account-id]
#
# The name check is a courtesy that fails fast. The account check is the one that matters:
# a profile can be renamed or re-pointed, so when the caller knows which account it means,
# the resolved identity has to agree before anything is touched.
require_aws_profile() {
  local profile="${1:-}" expected="${2:-}" denied actual
  if [[ -z "$profile" ]]; then
    echo "FAIL  --profile is required: this script will not guess which AWS account to touch"
    return 1
  fi
  for denied in "${AWS_DENIED_PROFILE_PREFIXES[@]}"; do
    if [[ "$profile" == "$denied" || "$profile" == "$denied-"* ]]; then
      echo "FAIL  the profile '$profile' belongs to another account and is never a deploy target"
      return 1
    fi
  done
  if [[ -n "$expected" ]]; then
    actual="$(aws sts get-caller-identity --profile "$profile" --query Account --output text 2>/dev/null)" || true
    if [[ -z "$actual" ]]; then
      echo "FAIL  '$profile' has no live session: run 'aws sso login --profile $profile'"
      return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
      echo "FAIL  '$profile' resolves to account $actual, not $expected"
      return 1
    fi
  fi
  return 0
}
