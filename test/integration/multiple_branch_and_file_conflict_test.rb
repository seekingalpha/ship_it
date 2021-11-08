require 'test_helper'
require 'stringio'

require 'ship_it/rebuild_staging'

class MultipleBranchAndFileConflictTest < RepoTest
  include ResolveHelpers

  def teardown
    super
    FileUtils.rm_f('failed_report.json')
  end

  def merge_and_rebuild(branch, with_user=false)
    if with_user
      resolve_merge_with_resolution_request(branch, 1)
    else
      resolve_merge_without_user_request(branch.name, 1)
    end
    assert rebuild, ->{@log.string}
    refute File.exist?('failed_report.json'), ->{source=caller_locations(4,1)[0];"Called from #{source.path}:#{source.lineno}\n"+IO.read('failed_report.json')+@log.string}
    @git.checkout('master')
    @git.push("origin/#{handler.target_test_branch}", @git.target)
    flush_log
  end

  def test_can_build_resolution_for_conflict_hitting_two_branches_that_are_also_in_the_same_conflict
    add_file('master', 'test_file')
    @git.push('master')
    @git.push('master', @git.target)

    branch1 = add_branch(fname: 'test_file')
    merge_and_rebuild(branch1)

    # conflict #1
    branch2 = add_branch(fname: 'test_file')
    merge_and_rebuild(branch2, true)
    conflict_branch = @git.current_branch_list.map(&:first).find { |branch| branch.start_with?(MergeHelpers::CONFLICT_NAME) }
    @git.drop_branch(conflict_branch) # this conflict is expected to NOT exist on the local machine

    # conflict #2
    branch3 = add_branch(fname: 'test_file')
    merge_and_rebuild(branch3, true)
    assert_equal 7, @git.current_branch_list.size, IO.read('new_branches.list')+"\n"+@log.string
    refute File.exist?('failed_report.json'), @log.string
    refute rebuild, ->{@log.string} # rebuilding when everything is in will error out
  end

  def rebuild force:false, push:true, json:true
    handler(force, push, json).run
    true
  rescue StandardError
    false
  end

  def handler force=false, push=true, json=true
    RebuildStaging.new(logger: Logger.new(@log), git: @git, quiet: false, push: push, force: force, json: json)
  end
end
