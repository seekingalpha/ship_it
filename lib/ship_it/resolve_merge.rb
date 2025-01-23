#!/usr/bin/env ruby
require 'ship_it/merge_helpers'

class ResolveMerge < MergeHelpers
  NO_NEW_BRANCHES_MESSAGE = "Unable to resolve any branches!"
  BRANCHES_MISSING_MESSAGE = "Couldn't resolve some branches. Use -f to ignore."
  RESOLVE_REQUEST = "Please resolve the merge conflict in another terminal, commit, come back here and press Enter to continue."
  RESOLVE_NOT_FINISHED_REQUEST = "Merge conflict still not resolved, see above and try again."
  USAGE_QUERY = 'Can I use it? [Y/n] '

  def self.add_options parser, options
    super
    parser.on('-f', '--force', 'Force merge if only some branches exist.') do |force|
      options[:force] = force
    end
  end

  def check_or_create_target
    @git.query_rev("#{@git.remote}/#{@git.target}")
  rescue
    @git.push("#{@git.remote}/master", @git.target)
  end

  def target_in_master?
    commit_id = @git.query_rev("#{@git.remote}/#{@git.target}")
    @git.branch_in?(commit_id, "#{@git.remote}/master")
  rescue
    false
  end

  def process
    load_branches
    @skipped_resolutions = []
    check_or_create_target
    check_branches_not_in_target
    if simple_merge || rebased_merge
      @logger.info 'Merge successful!'
      write_list @new_branches
      write_list @skipped_resolutions, 'removed'
    else
      @logger.info 'Testing against all branches...'
      check_against_master
      resolves = resolve_broken_branches
      write_list resolves+@new_branches
    end
  end

  def linear_merge
    branch_map = @branches.reduce({}) do |hash, branch|
      hash[branch.name] = branch
      hash
    end
    @new_branches.all? {|updated| !branch_map[updated.name] || @git.branch_in?(branch_map[updated.name].commit_id, updated.commit_id)}
  end

  def simple_merge
    stable_master = @git.branch_in?("#{@git.remote}/master", "#{@git.remote}/#{@git.target}")
    if stable_master && linear_merge
      @status = check_against(@git.target)
      @status.ok?
    end
  end

  def rebased_merge
    branch_names = @branches.map(&:first)
    if (branch_names && @new_branch_names).size == @new_branch_names.size
      commit_id = rebuild_target
      @status = check_against(@git.target, commit_id)
    end
    @status.ok?
  end

  def write_list branches, prefix = 'new'
    list = []
    branches.each do |branch|
      if ('new' == prefix) && !@git.branch_in?(branch.commit_id, "#{@git.remote}/#{branch}")
        @git.push branch.name
      end
      list << branch.log
    end
    BranchList.write("#{prefix}_branches.list", list)
  end

  def resolve_broken_branches
    broken_branches = @status.broken
    broken_names = broken_branches.map(&:name)
    resolves = []

    branches_in_resolves = []
    @branches.each do |branch|
      if broken_names.include?(branch.name) # not a conflict
        next
      end
      if branch.resolution?
        next
      end

      broken_branches.each do |broken_branch|
        names = [branch, broken_branch].map(&:name)
        resolve_name = CONFLICT_NAME + names.sort.join('+')
        unless resolves.any? {|rbranch| rbranch.name == resolve_name}
          fix = resolve_merge(branch.name, branch.commit_id, [broken_branch])
          if fix
            resolves << fix
            branches_in_resolves += names
          end
        end
      end
    end
    branches_in_resolves.uniq!
    extra_resolves = branches_in_resolves.map do |bname|
      @resolution_branches[bname].to_a.select do |rbranch|
        conflict_list = rbranch.conflict_branches
        (conflict_list & branches_in_resolves).size > 0 &&
          resolves.none? { |newr| newr.name == rbranch.name }
      end
    end.flatten(1).uniq
    @logger.debug "Main resolves: #{resolves.map(&:name)}"
    @logger.debug "Extra resolves: #{extra_resolves.map(&:name)}"
    all_resolves = resolves + extra_resolves
    if all_resolves.size > 1
      resolves.unshift resolve_merge('master', nil, all_resolves)
    end

    resolves
  end

  def figure_fix_branch branch, broken_branches
    branches = [branch] + broken_branches.map(&:conflict_or_normal_branches).flatten(1)
    branches -= ['master'] # master is just the base
    "#{CONFLICT_NAME}#{branches.uniq.sort.join('+')}"
  end

  def resolve_merge branch, commit_id, broken_branches
    @logger.info "Testing merge to #{branch}" + (commit_id ? " (#{commit_id})" : "")
    success, output = test_merge(broken_branches, branch, commit_id)
    return if success && !broken_branches.any?(&:resolution?)

    if success
      @logger.info "Coalescing conflict resolutions!"
    else
      @logger.error "Merge with #{branch} failed!"
    end

    fix_branch = figure_fix_branch(branch, broken_branches)
    if !success
      fix_response = try_fix(fix_branch, broken_branches, branch, commit_id)
      if fix_response.is_a?(Branch)
        return fix_response
      elsif :fix_failed == fix_response || broken_branches.size>0
        stepped_resolve_merge(branch, commit_id, broken_branches)
      else
        $stdout.puts output
        request_user_fix
      end
    end

    rename_branch fix_branch, force: true
    Branch.new(fix_branch, @git.query_rev(fix_branch), current_commiter)
  end

  def stepped_resolve_merge branch, commit_id, broken_branches
    @logger.info "Building conflict resolution on top of #{branch}" + (commit_id ? " (#{commit_id})" : "")
    reset_test_branch(commit_id || "#{@git.remote}/#{branch}")
    broken_branches.each do |bbranch|
      @logger.info "Merging #{bbranch}"
      success, output = @git.merge(bbranch.commit_id, message: "Merge branch '#{bbranch}'")
      if !success
        $stderr.puts output
        request_user_fix
      end
    end
  end

  def request_user_fix
    $stdout.print RESOLVE_REQUEST
    $stdin.gets
    while @git.unclean?
      $stdout.print RESOLVE_NOT_FINISHED_REQUEST
      $stdin.gets
    end
  end

  def try_fix fix_branch, broken_branches, branch, commit_id
    response = nil
    fix_branch = "#{@git.remote}/#{fix_branch}"
    if @git.query_rev_name(fix_branch)
      fix_branch = Branch.new(fix_branch, @git.query_rev(fix_branch), current_commiter)
      success, _output = test_merge([fix_branch, *broken_branches], branch, commit_id)
      if success
        @logger.info "#{fix_branch} found"
        $stdout.print USAGE_QUERY
        answer = $stdin.gets
        answer.strip!
        if answer.empty? || 'Y' == answer[0].upcase
          @logger.info "Adding #{fix_branch}"
          fix_branch.name = fix_branch.name.split('/')[-1]
          response = fix_branch
        end
      end
    else
      response = :no_fix
    end
    response || :fix_failed
  end

  def set_new_branches branches
    @new_branches = []
    @new_branch_names = []
    branches.each do |branch|
      if @git.query_rev_name(branch)
        @new_branches << Branch.new(branch, @git.query_rev(branch), current_commiter)
        @new_branch_names << branch
      end
    end
    if target_in_master?
      includes_target = []
    else
      includes_target = @new_branches.select do |branch|
        @git.branch_in?("#{@git.remote}/#{@git.target}", branch.commit_id)
      end
      includes_target.delete_if {|branch| branch.name == 'master'}
    end

    if @new_branches.none?
      raise NO_NEW_BRANCHES_MESSAGE
    elsif @new_branches.size < branches.size && !@options[:force]
      raise BRANCHES_MISSING_MESSAGE
    elsif includes_target.size > 0
      raise "Branch(es) includes #{@git.target}: \n- #{includes_target.map(&:first).join("\n- ")}"
    end
    self
  rescue StandardError => e
    report_error(e)
  end

  def load_branches
    super
    @resolution_branches = {}
    @branches.each {|branch| build_resolution_branch(branch)}
  end

  def build_resolution_branch(branch)
    branch.conflict_branches.each do |mbranch|
      (@resolution_branches[mbranch] ||= []) << branch
    end
  end

  def rebuild_target
    @logger.info "Rebuilding #{@git.target} without rewritten branches"
    reset_test_branch("#{@git.remote}/master")
    selected_branches = @branches.select {|branch| !@new_branch_names.include?(branch.name)}
    _new_branches, @bad_branches, @skipped_resolutions = mass_merge(selected_branches, current_branches: [])
    @git.query_rev('HEAD')
  end

  def check_branches_not_in_target
    branches = @branches.map {|branch| [branch.name, branch.commit_id]}
    new_branches = @new_branches.map {|branch| [branch.name, branch.commit_id]}
    branches_in_target = (branches & new_branches).map {|branch, *_| branch}
    if branches_in_target.size == new_branches.size
      raise "All branches already in #{@git.target}!"
    end
    @new_branches.delete_if {|branch| branches_in_target.include?(branch.name)}
    @new_branch_names.delete_if {|bname| branches_in_target.include?(bname)}
  end

  class MergeStatus < Hash
    attr_accessor :merged
    def ok?
      all? {|k, (status,_message)| status} && merged?
    end

    def broken?
      any? {|k, (status,_message)| !status}
    end
    def broken
      select {|k, (status,_message)| !status}.map(&:first)
    end

    def merged?
      size == 1 || merged.to_a[0]
    end

    def messages
    end
  end

  def check_against target, commit_id=nil, to_check=@new_branches
    @logger.info "Testing merge to #{target}" + (commit_id ? " (#{commit_id})" : "")
    to_check.reduce(MergeStatus.new) do |h, branch|
      h[branch] = test_merge([branch], target, commit_id)
      h
    end
  end

  def check_against_master
    status = check_against('master')
    if status.broken?
      raise "Merge/rebase the following with master: #{status.broken.map(&:first).join(', ')}"
    end
  end
end
