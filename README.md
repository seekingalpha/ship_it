# ShipIt

ship-it utils to deploy using CI

## Installation

1. Add ship-it to your `Gemfile` and `bundle install`:
    ```ruby
    gem 'ship_it', git: 'https://github.com/seekingalpha/ship_it.git'
    ```

2. Add the needed binstubs:
    ```bash
    bundle binstubs ship-it unship-it
    ```

3. Require `ship_it/tasks` in your Rakefile

4. Implement `bin/test-ci-online` and `bin/queue-ship-it`.
   This two have to exist and be executable.
   `bin/test-ci-online` should succeed in case the connection to your CI server is working.
   `bin/queue-ship-it` is the script that will send the two files created by `ship-it` to the CI server.
   Complete examples based on Jenkins are located under the `examples` directory.

5. Create a `staging_history` branch.
   This is the branch `ship-it` will be using to record the staging branch list history.

    ```bash
    rake shipit:history_branch
    ```

    Pass `[branch_name]` if you want to use a different branch as the target for ship-it.

## Usage

`bin/ship-it` will 

To "ship" other branches, run `ship-it branch_name`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb` and push a tag of the version.
