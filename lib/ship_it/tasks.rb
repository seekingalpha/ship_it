require 'ship_it/git_actions'

namespace :shipit do
  desc "Add history branch for the given branch (target: staging, git_log: false)"
  task :history_branch, :target, :git_log do |t, args|
    target = args[:target]
    with_log = args[:log]
    git = GitActions.new(target)
    if args[:git_log] != 'true'
      git.set_logger Logger.new('/dev/null')
    end
    puts "Adding branch #{git.history_branch}"
    git.init_history_branch
  end
end
