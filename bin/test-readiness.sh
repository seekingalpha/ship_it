if [ ! -x bin/queue-ship-it ]; then
  echo Implement bin/queue-ship-it to ship the code to your CI system!
  exit 1
fi

if [ ! -x bin/test-ci-online ]; then
  echo Implement bin/test-ci-online!
  exit 2
fi

bin/test-ci-online || exit
