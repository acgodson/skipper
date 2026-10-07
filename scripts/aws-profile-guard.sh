#!/usr/bin/env bash
# Guard for every script that talks to AWS. Sourced, never run.
#
# Two rules, and both exist because this machine has credentials for accounts that are
# not ours: a script never guesses which account to touch, and the profiles belonging to
# the frozen box and to the other tenant are never a deploy target. Widening this list is
# a deliberate edit, in a review, not a flag.

AWS_DENIED_PROFILES=(godson regina)

# require_aws_profile <profile>
require_aws_profile() {
  local profile="${1:-}" denied
  if [[ -z "$profile" ]]; then
    echo "FAIL  --profile is required: this script will not guess which AWS account to touch"
    return 1
  fi
  for denied in "${AWS_DENIED_PROFILES[@]}"; do
    if [[ "$profile" == "$denied" ]]; then
      echo "FAIL  the profile '$profile' belongs to another account and is never a deploy target"
      return 1
    fi
  done
  return 0
}
