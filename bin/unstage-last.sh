#!/bin/sh
git checkout staging_history
git reset --hard origin/staging_history~1
git push -f origin HEAD:staging_history
