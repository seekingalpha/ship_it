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

if [ -n "$(grep -E '^[^#].*(:path|path:)' Gemfile)" ]; then
  echo Gemfile includes paths!
  exit 1
fi

rm -f removed_branches.list
BRANCH=${*:-`git rev-parse --abbrev-ref HEAD`}
SHIP_IT_LOC=$( cd "$(dirname "$0")"/.. ; pwd -P )

echo "Fetching..."
git fetch --prune
echo

for br in $BRANCH; do
  git branch $br origin/$br 2> /dev/null #will create local branch if there's none yet
  if [ -n "$(git log -1 --oneline $br..origin/$br)" ]; then
    echo "Error! There are commits on origin/$br that are not on $br:"
    git shortlog $br..origin/$br
    echo "I can't force-update your local branch, so either do it yourself, or create new branch. Bye bye."
    exit 1
  fi
done

$SHIP_IT_LOC/exe/resolve-merge ${BRANCH} || exit
bin/queue-ship-it
