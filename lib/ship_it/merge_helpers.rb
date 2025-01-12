require 'optparse'
require 'ship_it/git_actions'

class MergeHelpers
  MERGE_TEST_BRANCH = 'predeploy_merge_test'.freeze # should never be pushed
  DEFAULTS = {quiet: true, target: 'staging', remote: 'origin'}

  CONFLICT_NAME = 'conflict-'.freeze
  CONFLICT_START = CONFLICT_NAME.size

  attr_reader :branches

  Branch = Struct.new(:name, :commit_id, :commiter, :reason) do
    def to_s
      name
    end

    def ===(other_branch)
      other_branch.class == self.class && name == other_branch.name && commit_id == other_branch.commit_id
    end

    def dump
      {branch: name, commit_id: commit_id, reason: reason}
    end

    def log
      [name, commit_id, commiter]
    end

    def resolution?
      name.start_with?(CONFLICT_NAME)
    end

    def conflict_branches
      if resolution?
        name[CONFLICT_START..-1].to_s.split('+')
      else
        []
      end
    end

    def conflict_or_normal_branches
      resolution? ? conflict_branches : [name]
    end
  end

  def self.add_options parser, options
    parser.on('-v', '--verbose', 'Turn on verbose mode') do
      options[:quiet] = false
    end
    parser.on('-t', '--target=BRANCH', 'Target branch. Default staging') do |branch|
      options[:target] = branch
    end
    parser.on('-r', '--remote=REMOTE', 'Remote to use. Default origin') do |remote|
      options[:remote] = remote
    end
    parser.on('-pr', '--push-remote=REMOTE', 'Remote to use. Default identical to --remote') do |pr|
      options[:push_remote] = pr
    end
  end

  def self.from_argv
    options = self::DEFAULTS.dup
    argv_parser = OptionParser.new do |parser|
      parser.banner = "Usage: #{File.basename($0)} [options] branches"
      add_options(parser, options)
    end
    argv_parser.parse!
    options[:is_program] = true
    options[:push_remote] ||= options[:remote]
    options
  end

  def initialize options=self.class.from_argv
    @options = options
    init_logger
    @git = options[:git] || GitActions.new(options[:target], options[:remote], options[:push_remote])
    @git.set_logger(@logger)
    unless current_commiter.to_s.include?('@')
      raise "Commiter email not set in git!"
    end
  end

  def init_logger
    @logger = @options[:logger] || Logger.new(STDOUT)
    @logger.level = @options[:quiet] ? Logger::INFO : Logger::DEBUG
    @logger.formatter = proc do |severity, datetime, progname, msg|
      "#{severity}: #{msg}\n"
    end
    @logger
  end

  def process
    raise "No processing"
  end

  def run
    raise_if_bad_branch
    raise_if_unclean
    raise_if_no_history_branch
    @git.sync_to_origin
    process
  rescue GitActions::Exception, Interrupt, RuntimeError => e
    report_error(e)
  ensure
    @git.reset_state
    @git.drop_branch MERGE_TEST_BRANCH
  end

  def raise_if_bad_branch
    if @git.starting_branch == MERGE_TEST_BRANCH
      raise "The current branch is reserved for merge testing; please rename it."
    end
  end

  def raise_if_unclean
    if files = @git.unclean?
      raise %|Your working tree is not clean:\n#{files.join("\n")}\nCommit or reset and try again.|
    end
  end

  def raise_if_no_history_branch
    if !@git.query_rev_name("#{@git.remote}/#{@git.history_branch}")
      raise %|History branch for #{@git.target} is missing! Run rake shipit:history_branch[#{@git.target}] to create it.|
    end
  end

  def reset_test_branch target
    @git.clear_merges
    @git.checkout @git.starting_branch
    @git.reset_branch MERGE_TEST_BRANCH, target, track: false
    @git.checkout MERGE_TEST_BRANCH
  end

  def test_merges(branches, target, commit_id)
    message = branches.is_a?(Array) ? 'testing merge' : nil
    merge_to = commit_id || "#{@git.remote}/#{target}"
    [*branches].each do |branch|
      success, output = @git.merge_tree(merge_to, branch.commit_id, commit_with_message: message)
      return [false, output] unless success

      merge_to = output
    end
    [true, '']
  end

  def rename_branch new_name, force: false
    counter = 0
    test_name = new_name
    if force
      @git.drop_branch test_name
    end
    while !(result = @git.rename_to(test_name))[0].success?
      raise result[1] if counter > 10
      counter += 1
      test_name = "#{new_name}#{counter}"
    end
    test_name
  end

  def mass_merge branches, current_branches: @branches
    branches = filter_in_master(branches)
    branch_names = (current_branches + branches).map(&:first)

    new_branches = []
    bad_branches = []
    skipped_resolutions = []
    merge_to_commit_id = @git.query_rev('HEAD')
    branches.each do |branch|
      parts = missing_parts?(branch, branch_names)
      if parts.any?
        @logger.info "Dropping #{branch} - #{parts.join(',')} not in #{@git.target} anymore"
        branch_names -= [branch.name]
        skipped_resolutions << branch.dup.tap {|skipped| skipped.reason = "#{parts.join(',')} not in #{@git.target}"}
        next
      end

      success, output = @git.merge_tree(merge_to_commit_id, branch.commit_id, commit_with_message: "Merge branch '#{branch}'")
      if success
        merge_to_commit_id = output
        @logger.info "Merged #{branch} (#{branch.commit_id})"
        new_branches << branch.dup
      else
        @logger.info "Skipping #{branch} (#{branch.commit_id}) - doesn't merge cleanly"
        bad_branches << branch.dup.tap {|skipped| skipped.reason = clean_reason(output)}
        branch_names -= [branch]
      end
    end
    @git.reset_hard(merge_to_commit_id)

    [new_branches, bad_branches, skipped_resolutions]
  end

  def filter_in_master branches
    branches_in_master, branches = branches.partition do |branch|
      @git.branch_in?(branch.commit_id, "#{@git.remote}/master")
    end
    branches_in_master.each do |branch|
      @logger.info "Skipping #{branch} - merged into master"
    end
    branches
  end

  # Passes if the branch is:
  # - a regular branch
  # - a conflict with all base branches in the current list
  def missing_parts? branch, all_branches
    branch.conflict_branches - all_branches
  end

  CONFLICT_TYPES = {
    '(content):' => -1,
    '(add/add):' => 5,
    '(modify/delete):' => 2,
  }

  # Collect files and reasons from git conflict output
  def clean_reason output
    output.lines.grep(/^CONFLICT/).map do |line|
      parts = line.strip.split(' ')
      file_index = CONFLICT_TYPES[parts[1]]
      if file_index
        parts[file_index]
      else
        line.strip
      end
    end.join(', ')
  end

  def current_commiter
    @current_commiter ||= ENV['commiter'] || @git.local_commiter_email
  end

  def report_error e
    e.to_s.lines.each do |line|
      @logger.error line.chomp
    end
    @logger.error e.backtrace unless @options[:quiet]
    if @options[:is_program]
      exit 1
    else
      new_error = StandardError.new("#{e.class.name}: #{e.message}")
      new_error.set_backtrace e.backtrace
      raise new_error
    end
  end

  def load_branches
    @branches = @git.current_branch_list.map {|branch_data| Branch.new(*branch_data)}
  end
end
