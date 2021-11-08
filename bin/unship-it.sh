#!/bin/sh

## Disable OverCommit-managed Git Hooks (https://github.com/sds/overcommit).
## 1. We don't want to slow down (or worse, break!) the merge process with
##    repeated RuboCop (and other) checks.
## 2. The merge commit subject lines can often get pretty long
##    ("Merge remote-tracking branch 'origin/…' into predeploy_master"
##     is 60 chars + the branch name).
##    I want to enforce TextWidth on _regular_ commits but SKIP it here.
export OVERCOMMIT_DISABLE=${OVERCOMMIT_DISABLE:-1}

SHIP_IT_LOC=$( cd "$(dirname "$0")"/.. ; pwd -P )
$SHIP_IT_LOC/bin/test-readiness.sh || exit

rm -f new_branches.list
BRANCHES=${*:-`git rev-parse --abbrev-ref HEAD`}
if [ "$BRANCHES" = "all" ]; then
  echo all > removed_branches.list
else
  git fetch -q
  git show origin/staging_history:.branches.list|grep -E "^($(echo $BRANCHES|tr ' ' '|'))," > removed_branches.list
  if [ -z "$(cat removed_branches.list)" ]; then
    rm -f removed_branches.list
    echo No such branch
    exit 1
  fi
fi

bin/queue-ship-it
