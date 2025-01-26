require 'test_helper'
require 'stringio'

require 'ship_it/rebuild_staging'

class RebuildStagingTest < RepoTest
  def setup
    super
    @log = StringIO.new
  end

  def teardown
    super
    FileUtils.rm_f('failed_report.json')
  end

  def flush_log
    @log.truncate(0)
    @log.rewind
  end

  def test_parses_defaults_of_the_correct_class
    assert RebuildStaging.from_argv[:push]
    assert RebuildStaging.from_argv[:push_remote]
  end

  def test_old_branches_equal_all_branches_when_new_branch_given
    build_staging 2
    flush_log
    new_branch = add_branch
    write_list([new_branch])
    builder = handler
    builder.load_branch_lists
    builder.setup_extra_data
    assert_equal @branches.values, builder.branches_without_change_requests
  end

  def test_old_branches_do_not_include_updated_branch
    build_staging 2
    flush_log
    updated_branch = @branches.values.last
    add_file(updated_branch, 'other_file')
    write_list([updated_branch])
    builder = handler
    builder.load_branch_lists
    builder.setup_extra_data
    assert_equal [@branches.values.first], builder.branches_without_change_requests
  end

  def test_old_branches_do_not_include_conflict_of_updated_branch
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    flush_log
    updated_branch = branch_data[1]
    add_file(updated_branch, 'other_file')
    write_list([updated_branch])
    builder = handler
    builder.load_branch_lists
    builder.setup_extra_data
    assert_equal @branches.values, builder.branches_without_change_requests
  end

  def test_old_branches_include_conflict_with_merged_to_master_branches_only_if_delayed
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    add_to_master(@branches.keys[0])
    flush_log
    updated_branch = branch_data[1]
    add_file(updated_branch[0], 'other_file')
    write_list([updated_branch])
    builder = handler
    builder.load_branch_lists
    builder.setup_extra_data
    builder.setup_test_branch
    assert_empty builder.branches, @log.string
    builder = handler(delayed_conflict_drop: true)
    flush_log
    builder.load_branch_lists
    builder.setup_extra_data
    builder.setup_test_branch
    branch_data[0].reason = @branches.keys[0]
    assert_equal branch_data, builder.branches, @log.string
  end

  def test_will_build_a_new_staging
    branch_data = Array.new(3) { add_branch }
    write_list(branch_data)
    @git.drop_branch('origin/predeploy_staging')
    assert rebuild
    assert_equal branch_data.map(&:log), @git.current_branch_list
    assert @git.query_rev_name('origin/predeploy_staging')
  end

  def test_will_not_push_with_push_false
    branch_data = Array.new(3) { add_branch }
    write_list(branch_data)
    assert rebuild(push: false)
    assert_empty @git.current_branch_list
    refute @git.query_rev_name('origin/predeploy_staging')
  end

  def test_will_add_branch_to_staging
    build_staging 1
    rev = @git.query_rev('origin/staging')
    new_branch = add_branch
    write_list([new_branch])
    flush_log
    assert rebuild
    assert_equal((@branches.values + [new_branch]).map(&:log), @git.current_branch_list)
    assert_equal rev, @git.query_rev("origin/#{handler.target_test_branch}~1"), @log.string
  end

  def test_will_rebuild_staging_after_merge_to_master
    build_staging 2
    add_to_master(@branches.keys[0])
    rev = @git.query_rev('origin/master')
    flush_log
    new_branch = add_branch
    write_list([new_branch])
    assert rebuild, -> { @log.string }
    assert_equal [@branches.values[1], new_branch].map(&:log), @git.current_branch_list, @log.string
    assert_equal rev, @git.query_rev("origin/#{handler.target_test_branch}~2"), @log.string
  end

  def test_will_rebuild_staging_after_merge_to_master_with_delayed_option
    build_staging 2
    add_to_master(@branches.keys[0])
    rev = @git.query_rev('origin/master')
    flush_log
    new_branch = add_branch
    write_list([new_branch])
    assert rebuild(delayed_conflict_drop: true), -> { @log.string }
    assert_equal [@branches.values[1], new_branch].map(&:log), @git.current_branch_list, @log.string
    assert_equal rev, @git.query_rev("origin/#{handler.target_test_branch}~2"), @log.string
  end

  def test_force_rebuild
    build_staging 2
    revs = [@git.query_rev('origin/staging~1'), @git.query_rev('origin/staging')]
    write_list([])
    flush_log
    assert rebuild(force: true)
    assert_equal @branches.values.map(&:log), @git.current_branch_list
    refute_equal revs[0], @git.query_rev("origin/#{handler.target_test_branch}~1"), @log.string
    refute_equal revs[1], @git.query_rev("origin/#{handler.target_test_branch}"), @log.string
    refute File.exist?('failed_report.json')
  end

  def test_clear_staging
    build_staging 2
    write_list([['all']], 'removed')
    assert rebuild
    assert_empty @git.current_branch_list
    refute File.exist?('failed_report.json')
  end

  def test_refuse_to_build_with_no_changes
    build_staging 2
    write_list([])
    flush_log
    refute rebuild
    assert_match(/based on current master/, @log.string, @log.string)
    refute File.exist?('failed_report.json')
  end

  def test_fail_to_merge_anything_json
    build_staging 1
    bad_file = default_branch_file(@branches.values.first)
    branch = add_branch(fname: bad_file)
    write_list([branch])
    flush_log
    refute rebuild
    assert_match(/No changes made.*rebuild failed/, @log.string, @log.string)
    data = JSON.parse(IO.read('failed_report.json'))
    assert_equal [@git.local_commiter_email], data.keys
    bad_branch, bad_commit, bad_user = branch.log
    bad_reason = "Conflicted with staging"
    assert_equal [bad_reason], data.values[0].keys
    assert_equal [{'branch' => bad_branch, 'commit_id' => bad_commit, 'reason' => bad_file}], data[bad_user][bad_reason]
  end

  def test_fail_to_merge_anything_text
    build_staging 1
    branch = add_branch(fname: default_branch_file(@branches.values.first))
    write_list([branch])
    flush_log
    refute rebuild(json: false)
    assert_match(/No changes made.*rebuild failed/, @log.string, @log.string)
    refute File.exist?('failed_report.json')
    assert_match(/^ERROR: - #{branch.name}/, @log.string, @log.string)
  end

  def test_merge_with_conflict_resolution
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    write_list(branch_data)
    flush_log
    assert rebuild, ->{@log.string}
    assert_equal((@branches.values + branch_data).map(&:log), @git.current_branch_list, @log.string)
    refute File.exist?('failed_report.json')
  end

  # TODO: need to make rebuild drop conflict resolutions of failed branch merges
  def test_will_leave_conflict_branch_in_when_conflicting_branch_modifies_conflicting_file_again_and_causes_another_conflict
    build_staging 1
    fname = default_branch_file(@branches.values.first)
    branch_data = make_conflicting_branch(@branches.values.first)

    # modify the conflicting file on the new branch
    add_file(branch_data[1], fname)
    write_list(branch_data)
    flush_log
    assert rebuild, ->{@log.string}
    assert_equal((@branches.values + [branch_data[0]]).map(&:log), @git.current_branch_list, @log.string)
    data = JSON.parse(IO.read('failed_report.json'))
    assert_equal([@git.local_commiter_email], data.keys)
    branch_report = build_report([branch_data[1]], fname)
    assert_equal({ 'Conflicted with staging' => branch_report }, data.values[0])
  end

  def test_failure_on_merge_with_old_conflict_resolution_on_original_side
    build_staging 1
    first_branch = @branches.values.first
    fname = default_branch_file(first_branch)
    branch_data = make_conflicting_branch(first_branch)

    # modify the conflicting file on the first branch
    add_file(first_branch, fname)
    @git.push(first_branch.name)
    write_list(@branches.values)
    flush_log
    assert rebuild, ->{@log.string}
    @git.checkout('master')
    @git.push("origin/#{handler.target_test_branch}", @git.target)

    # now try to use the out-of-date conflict resolution
    write_list(branch_data)
    refute rebuild, ->{`git show origin/#{handler.target_test_branch}:#{fname}`+"\n"+@log.string}
    assert_equal @branches.values.map(&:log), @git.current_branch_list, @log.string
    data = JSON.parse(IO.read('failed_report.json'))
    assert_equal [@git.local_commiter_email], data.keys
    branch_report = build_report(branch_data, fname)
    assert_equal({ 'Conflicted with staging' => branch_report }, data.values[0])
  end

  def test_drop_conflict_and_branch_after_merge_to_master_with_new_branch
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    fname = default_branch_file(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    add_to_master(@branches.keys[0])
    flush_log

    # updating after merge of first branch to master...
    unrelated_branch = add_branch
    write_list([unrelated_branch])
    assert rebuild, -> { @log.string }
    assert_equal [unrelated_branch[0]], @git.current_branch_list.map(&:first), @log.string
    data = JSON.parse(IO.read('failed_report.json'))
    branch_report = build_report([branch_data[1]], fname)
    assert_equal({ 'Conflicted with master' => branch_report }, data.values[0])
  end

  def test_drop_conflict_and_branch_after_merge_to_master_with_update
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    fname = default_branch_file(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    add_to_master(@branches.keys[0])
    flush_log

    # updating after merge of first branch to master...
    updated_branch = branch_data[1]
    add_file(updated_branch, default_branch_file(updated_branch))
    write_list([updated_branch])
    assert rebuild, -> { @log.string }
    assert_empty @git.current_branch_list, @log.string
    data = JSON.parse(IO.read('failed_report.json'))
    branch_report = build_report([updated_branch], fname)
    assert_equal({ 'Conflicted with staging' => branch_report }, data.values[0])
  end

  def test_leave_conflict_for_one_round_after_merge_to_master
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    add_to_master(@branches.keys[0])
    flush_log

    # updating after merge of first branch to master...
    updated_branch = branch_data[1]
    add_file(updated_branch, default_branch_file(updated_branch))
    write_list([updated_branch])
    assert rebuild(delayed_conflict_drop: true), -> { @log.string }
    assert_equal branch_data.map(&:log), @git.current_branch_list, @log.string
    data = JSON.parse(IO.read('failed_report.json'))
    assert_equal [@git.local_commiter_email], data.keys
    branch_report = build_report([branch_data[0]], @branches.keys[0])
    assert_equal({ 'In master - will be dropped next deploy' => branch_report }, data.values[0], @log.string)

    # updating again
    add_file(updated_branch, default_branch_file(updated_branch))
    write_list([updated_branch])
    assert rebuild(delayed_conflict_drop: true), -> { @log.string }
    assert_empty @git.current_branch_list, @log.string
    data = JSON.parse(IO.read('failed_report.json'))
    assert_equal [@git.local_commiter_email], data.keys
    branch_report = build_report([updated_branch], default_branch_file(@branches.values.first))
    assert_equal({ 'Conflicted with staging' => branch_report }, data.values[0], @log.string)
  end

  def test_leave_conflict_for_one_round_if_deploying_something_else
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    add_to_master(@branches.keys[0])
    flush_log

    # adding unrelated branch...
    new_branch = add_branch
    write_list([new_branch])
    flush_log
    assert rebuild(delayed_conflict_drop: true), -> { @log.string }
    data = JSON.parse(IO.read('failed_report.json'))
    assert_equal [@git.local_commiter_email], data.keys
    branch_report = build_report([branch_data[0]], @branches.keys[0])
    assert_equal({ 'In master - will be dropped next deploy' => branch_report }, data.values[0], @log.string)
    assert_equal branch_data.map(&:name) + [new_branch.name], @git.current_branch_list.map(&:first), @log.string
  end

  def test_drop_conflict_and_branch_if_branch_is_gone
    build_staging 1
    branch_data = make_conflicting_branch(@branches.values.first)
    write_list(branch_data)
    assert rebuild, -> { @log.string }
    add_to_master(@branches.keys[0])
    @git.drop_remote(branch_data[1].name)
    flush_log

    # adding unrelated branch...
    new_branch = add_branch
    write_list([new_branch])
    flush_log
    assert rebuild(delayed_conflict_drop: true), -> { @log.string }
    refute File.exist?('failed_report.json')
    assert_equal [new_branch.name], @git.current_branch_list.map(&:first), @log.string
  end

  def test_leaves_unrelated_conflicts_alone
    build_staging 3
    branch_data = make_conflicting_branch(@branches.values[1])
    write_list(branch_data)
    flush_log
    assert rebuild, ->{@log.string}
    assert_equal((@branches.values + branch_data).map(&:log), @git.current_branch_list, @log.string)

    updated_branch = @branches.values.last
    add_file(updated_branch, default_branch_file(updated_branch))
    write_list([updated_branch])
    flush_log
    assert rebuild, ->{@log.string}
    assert_equal((@branches.values[0, 2]+branch_data+[updated_branch]).map(&:log), @git.current_branch_list, @log.string)
    refute File.exist?('failed_report.json')
  end

  def test_leaves_both_conflicting_branch_after_regular_update
    build_staging 2
    resolution_1, con_branch = make_conflicting_branch(@branches.values.first)
    resolutions = [resolution_1]
    add_file(con_branch, default_branch_file(@branches.values.last))
    resolution_2 = make_resolution_branch([con_branch], @branches.keys.last)
    resolutions.push resolution_2
    resolutions.insert 0, make_resolution_branch(resolutions, 'master')
    write_list(resolutions + [con_branch])
    flush_log
    assert rebuild, -> { @log.string }
    assert_equal (@branches.values + resolutions + [con_branch]).map(&:log), @git.current_branch_list, @log.string

    updated_branch = @branches.values[1]
    add_file(updated_branch, 'other_file')
    write_list([updated_branch])
    flush_log
    assert rebuild, -> { @log.string }
    assert_equal [@branches.values.first, *resolutions, con_branch, updated_branch].map(&:log), @git.current_branch_list, @log.string
    refute File.exist?('failed_report.json')
  end

  # Resolution reordering fix. Originally, updating branch #1 that conflicted
  # with #3 and #4 broke resolution order.
  # Tables show merge list in staging
  # Initial State   | #1 Update
  # ------------------------------
  # 1               | moved to end
  # conflict-1-3    | moved to end
  # 3               | 3
  # conflict-1-3-4  | moved to end
  # conflict-1-4    | moved to end
  # 4               | 4
  #                 | conflict-1-3 - fail! conflicts with #4
  #                 | conflict-1-3-4
  #                 | 1
  # Next, #4 is deployed:
  # Initial State  | Update
  # 3              | 3
  # 4              | moved to end
  # conflict-1-3-4 | moved to end
  # 1              | conflicts with #3 and gets dropped
  #                | conflict-1-3-4 is dropped - "not needed"
  #                | 4
  # The fix forces conflict-* branches to be ordered by number of branches
  # they collect, so 1-3-4 always comes before 1-3, 1-4, etc.
  # #2 in the test is an example of an unrelated branch
  def test_leaves_all_resolutions_after_update_to_branch_conflicting_with_two
    @git.push('origin/master', @git.target)
    branch_1 = add_branch
    add_file(branch_1, 'conflict_1')
    add_file(branch_1, 'conflict_2')
    merge(branch_1)
    branch_2 = add_branch
    merge(branch_2)
    resolution_3, branch_3 = make_conflicting_branch(branch_1, fname: 'conflict_1')
    merge(resolution_3)
    merge(branch_3)
    resolution_4, branch_4 = make_conflicting_branch(branch_1, fname: 'conflict_2')
    super_res = make_resolution_branch([resolution_3, resolution_4], 'master')
    merge(super_res)
    merge(resolution_4)
    merge(branch_4)
    flush_log

    add_file(branch_1, 'other_file')
    write_list([branch_1])
    flush_log
    assert rebuild, -> { @log.string }
    assert_equal [branch_2, branch_3, branch_4, super_res, resolution_3, resolution_4, branch_1].map(&:log), @git.current_branch_list, @log.string
    refute File.exist?('failed_report.json')
  end

  # Previous test missed a problem with branch updates when there are more
  # branches in the resolution
  # After multiple updates:
  # Initial State      | #2 Update
  # -----------------------------------
  # 2                  | moved to end
  # 3                  | 3
  # 4                  | 4
  # conflict-1-2-3-4   | moved to end
  # conflict-1-2       | moved to end
  # conflict-1-3       | conflicts with #4! dropped!
  # conflict-1-4       | conflicts with #3! dropped!
  # 1                  | conflicts with #3 AND #4! dropped!
  #                    | conflict-1-2-3-4 is dropped - "not needed"
  #                    | conflict-1-2 is dropped
  #                    | 2
  # The code has to catch that multi-conflict-res is still needed and let it stay
  def test_leaves_all_resolutions_after_update_to_branch_conflicting_with_three
    @git.push('origin/master', @git.target)
    branch_2 = add_branch(fname: 'conflict_2')
    branch_3 = add_branch(fname: 'conflict_3')
    branch_4 = add_branch(fname: 'conflict_4')
    merge(branch_2)
    merge(branch_3)
    merge(branch_4)
    branch_1 = add_branch
    add_file(branch_1, 'conflict_2')
    add_file(branch_1, 'conflict_3')
    add_file(branch_1, 'conflict_4')
    resolution_2 = make_resolution_branch([branch_1], branch_2.name)
    resolution_3 = make_resolution_branch([branch_1], branch_3.name)
    resolution_4 = make_resolution_branch([branch_1], branch_4.name)
    super_res = make_resolution_branch([resolution_2, resolution_3, resolution_4], 'master')
    merge(super_res)
    merge(resolution_2)
    merge(resolution_3)
    merge(resolution_4)
    merge(branch_1)
    flush_log

    add_file(branch_2, 'other_file')
    write_list([branch_2])
    flush_log
    assert rebuild, -> { @log.string }
    refute File.exist?('failed_report.json'), (File.read('failed_report.json') rescue '')
    assert_equal [branch_3, branch_4, super_res, resolution_2, resolution_3, resolution_4, branch_1, branch_2].map(&:log), @git.current_branch_list, @log.string
  end

  def write_list(branch_list, prefix = 'new')
    data = branch_list.map do |branch|
      branch == ['all'] ? branch : branch.log
    end
    BranchList.write("#{prefix}_branches.list", data)
  end

  def rebuild(...)
    handler(...).run
    true
  rescue StandardError
    if /No changes made.*rebuild failed/ === $!.message || $!.message.include?('based on current master')
      false
    else
      raise
    end
  end

  def build_report(branch_data, fname)
    branch_data.map do |branch|
      { 'branch' => branch.name, 'commit_id' => branch.commit_id, 'reason' => fname }
    end
  end

  def handler(force: false, push: true, json: true,
              delayed_conflict_drop: false)
    RebuildStaging.new(logger: Logger.new(@log), git: @git, quiet: false,
                       force: force, push: push, json: json,
                       delayed_conflict_drop: delayed_conflict_drop)
  end

  def add_to_master(branch)
    @git.checkout('master')
    @git.merge(branch)
    @git.push('master')
  end
end
