require 'test_helper'
require 'stringio'

class ResolveMergeTest < RepoTest
  include ResolveHelpers

  def test_will_resolve_single_branch_merge
    add_branch branch: 'first'
    assert resolve_merge_without_user_request('first')
  end

  def test_will_resolve_when_staging_equal_master
    build_staging 0
    add_branch(branch: 'a')
    assert resolve_merge_without_user_request(['a']), @log.string
  end

  def test_will_resolve_multi_branch_merge
    add_branch branch: 'a'
    add_branch branch: 'b'
    assert resolve_merge_without_user_request(['a', 'b'])
  end

  def test_will_exit_on_no_real_branches
    assert_raises StandardError do
      resolve_merge_without_user_request(['a', 'b'])
    end
    assert_includes @log.string, ResolveMerge::NO_NEW_BRANCHES_MESSAGE, @log.string
  end

  def test_will_exit_on_some_real_branches
    add_branch branch: 'b'
    assert_raises StandardError do
      resolve_merge_without_user_request(['a', 'b'])
    end
    assert_includes @log.string, ResolveMerge::BRANCHES_MISSING_MESSAGE, @log.string
  end

  def test_will_exit_if_no_new_branches
    build_staging 3
    assert_raises StandardError do
      resolve_merge_without_user_request(@branches.keys)
    end
    assert_includes @log.string, 'All branches already in', @log.string
  end

  def test_will_fail_with_conflicting_master
    add_branch(branch: 'branch_a', fname: 'a')
    add_file('master', 'a')
    @git.push('master')
    assert_raises StandardError do
      resolve_merge_without_user_request(['branch_a'])
    end
    assert_includes @log.string, 'Merge/rebase the following with master: branch_a', @log.string
  end

  def test_will_fail_with_staging_in_branch
    build_staging 1
    add_branch(branch: 'branch_b')
    @git.checkout 'branch_b'
    @git.merge('origin/staging')
    assert_raises StandardError do
      resolve_merge_without_user_request(['branch_b'])
    end
    assert_includes @log.string, 'Branch(es) includes staging:', @log.string
  end

  def test_will_notice_rewritten_branch_and_rebuild_without_it_first
    build_staging 3
    first_branch = @branches.keys.first
    rewrite = add_branch(branch: first_branch)
    expected_checks = [rewrite]
    branch_debug = (@branches.values + [rewrite]).map(&:log).map(&:inspect)
    method_mock = ->(commit_id, message: nil){
      if expected_checks.empty?
        raise Minitest::Assertion, "Unexpected call to merge(#{commit_id}, #{message})\n#{@log.string}"
      end
      exp = expected_checks.shift
      if [exp.commit_id] != Array(commit_id)
        raise Minitest::Assertion, %|Bad call to merge! Expected #{exp.name} (#{exp.commit_id}), received #{commit_id.inspect}, #{message}\n#{branch_debug.join("\n")}\n#{caller[0,5].join("\n")}\n#{@log.string}|
      end
      @git.__minitest_stub__merge(commit_id, message: message)
    }
    flush_log
    @git.stub(:merge, method_mock) do
      resolve_merge_without_user_request(first_branch)
    end
    assert_empty expected_checks, lambda { "Not all expectations for merge fulfilled: #{expected_checks.inspect}"}
  end

  def test_skips_conflicting_branches_in_rebuild
    build_staging 3
    first_branch = @branches.keys.first

    # merge rewritten branch into master
    add_branch(branch: first_branch)
    @git.checkout('master')
    @git.merge(first_branch)
    @git.push('master')

    # cause rebuild with new master and old first branch
    second_branch = @branches.values[1]
    second_branch = add_branch(branch: second_branch.name)
    flush_log
    resolve_merge_without_user_request(second_branch.name)
    new_branch_list = BranchList.read('new_branches.list')
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_empty removed_branch_list, @log.string
    assert_equal [second_branch.log], new_branch_list, @log.string
    assert_includes @log.string, "Skipping #{first_branch}"
  end

  def test_will_expect_user_solution_on_conflict
    build_staging 1
    first_branch = @branches.values.first
    new_branch = add_branch(fname: default_branch_file(first_branch))
    flush_log
    resolve_merge_with_resolution_request(new_branch)
  end

  def test_early_branch_catches_late_conflicts
    build_staging 2
    new_branch = add_branch
    @branches.values.each do |branch|
      add_file(new_branch, default_branch_file(branch))
    end
    flush_log

    resolve_merge_with_resolution_request(new_branch)

    # expected: a+b+c, a+c, b+c, c
    expected_branches = [[*@branches.keys, new_branch], [@branches.keys[0], new_branch], [@branches.keys[1], new_branch]].map do |blist|
      MergeHelpers::CONFLICT_NAME+blist.join('+')
    end + [new_branch.name]
    new_branch_list = BranchList.read('new_branches.list')
    assert_equal 4, new_branch_list.size, new_branch_list.inspect + "\n" + @log.string
    assert_equal expected_branches, new_branch_list.map(&:first)

    new_branch_list.each { |branch| merge(MergeHelpers::Branch.new(*branch)) }
    old_branch = add_branch(branch: @branches.keys.first)
    flush_log

    resolve_merge_with_resolution_request(old_branch)

    # expected: a+b+c, a+c, a
    # a+b+c resolution should be redone as branch_a's conflict with branch_c changed,
    # BUT branch_c still conflicts with branch_b, so a new multi-resolution is needed.
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_empty removed_branch_list

    expected_branches = expected_branches[0, 2] + [@branches.keys[0]]
    new_branch_list = BranchList.read('new_branches.list')
    assert_equal 3, new_branch_list.size, new_branch_list.inspect + "\n" + @log.string
    assert_equal expected_branches, new_branch_list.map(&:first)
  end

  def test_overarching_branch_on_shared_branch_in_conflict
    build_staging 1
    first_branch = @branches.values.first
    complex_branch = add_branch
    last_branch = add_branch
    [first_branch, last_branch].each do |branch|
      add_file(complex_branch, default_branch_file(branch))
    end
    flush_log

    resolve_merge_with_resolution_request(complex_branch)
    new_branch_list = BranchList.read('new_branches.list')
    new_branch_list.each { |branch| merge(MergeHelpers::Branch.new(*branch)) }
    flush_log

    resolve_merge_with_resolution_request(last_branch)

    # expected: a+b+c, b+c, c
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_empty removed_branch_list

    expected_branches = [[first_branch, complex_branch, last_branch], [complex_branch, last_branch]].map do |blist|
      MergeHelpers::CONFLICT_NAME+blist.join('+')
    end + [last_branch.name]
    new_branch_list = BranchList.read('new_branches.list')
    assert_equal 3, new_branch_list.size, new_branch_list.inspect + "\n" + @log.string
    assert_equal expected_branches, new_branch_list.map(&:first)
  end

  def test_drops_resolution_after_branch_doesnt_need_it
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    branch_data.each { |branch| merge(branch) }
    branch = branch_data[1]
    @git.reset_branch(branch.name, @branches.keys.first, track: false)
    add_file(branch, default_branch_file(@branches.values.first))

    # don't need the resolution locally/someone else continuing the work
    assert @git.drop_branch branch_data[0]

    flush_log
    resolve_merge_without_user_request(branch.name)
    new_branch_list = BranchList.read('new_branches.list')
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_equal [branch.log], new_branch_list, new_branch_list.inspect + "\n" + @log.string
    assert_equal [branch_data[0].log], removed_branch_list
    assert_includes @log.string, 'Rebuilding staging without rewritten branches'
  end

  def test_should_add_unused_old_conflict_resolution_to_removed_list
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    branch_data.each { |branch| merge(branch) }
    branch = add_branch(branch: branch_data[1].name) # rewrite branch

    flush_log
    resolve_merge_without_user_request(branch.name)
    assert_includes @log.string, 'Rebuilding staging without rewritten branches'
    new_branch_list = BranchList.read('new_branches.list')
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_equal [branch.log], new_branch_list, new_branch_list.inspect + "\n" + @log.string
    assert_equal [branch_data[0].log], removed_branch_list, removed_branch_list.inspect
  end

  def test_will_get_working_resolution_or_require_new_one
    build_staging 1
    first_branch = @branches.values.first
    fix_branch_data, branch_data = make_conflicting_branch(first_branch)
    [fix_branch_data, branch_data].each { |branch| merge(branch) }

    fix_branch_data2, branch_data2 = make_conflicting_branch(first_branch)
    new_fix_branch = replace_branch fix_branch_data, fix_branch_data2
    new_branch = replace_branch branch_data, branch_data2

    flush_log
    resolve_merge_with_usage_request([first_branch, new_branch])
    new_branch_list = BranchList.read('new_branches.list')
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_equal [new_fix_branch.log, new_branch.log], new_branch_list, new_branch_list.inspect + "\n" + @log.string

    @git.drop_remote(fix_branch_data.name)
    flush_log
    resolve_merge_with_resolution_request([first_branch, new_branch])
    new_branch_list = BranchList.read('new_branches.list')
    removed_branch_list = BranchList.read('removed_branches.list')
    assert_equal 2, new_branch_list.size, new_branch_list.inspect + "\n" + @log.string
    assert_equal new_branch.log, new_branch_list[1], new_branch_list.inspect + "\n" + @log.string
  end

  def replace_branch(branch, branch_with_new_data)
    branch2_name = branch_with_new_data.name
    if !@git.query_rev_name(branch2_name)
      @git.reset_branch branch2_name, "origin/#{branch2_name}"
    end
    @git.checkout branch2_name
    @git.drop_branch branch.name
    @git.rename_to branch.name
    @git.push branch.name
    @git.drop_branch(branch) if branch.name.start_with?('conflict-')
    MergeHelpers::Branch.new(branch.name, branch_with_new_data.commit_id, branch.commiter)
  rescue
    puts @log.string
    raise
  end
end
