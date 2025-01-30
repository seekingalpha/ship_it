require 'fileutils'
require 'tmpdir'
require 'ship_it/resolve_merge'

# Test happening in a temporary directory, so we can play with git repositories
class ShipItTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    Dir.chdir(@dir)
  end

  def teardown
    FileUtils.remove_entry_secure(@dir, true)
    Dir.chdir(File.dirname(__FILE__))
  end

  def temp_file file_name, content, &block
    file = Tempfile.new(file_name, @dir)
    begin
      file.write(content)
      file.close
      block.call(file)
    ensure
      file.unlink
    end
  end
end

class RepoTest < ShipItTest
  def setup
    super
    setup_test_repo
    @test_char = 'a'
    @branches = {}
  end

  def setup_test_repo
    @git = GitActions.new
    @git.set_logger Logger.new('/dev/null')
    @git.init_repo
    @git.push(@git.history_branch)
    temp_file('zero_file', 'initial commit') do |file|
      @git.write_commit('master', 'initial commit', {'zero_file' => file.path}, origin: nil)
    end
    @git.update_ref('refs/remotes/origin/master', 'master')
    @git.checkout('master')
  end

  def build_staging(n_branches)
    n_branches.times do
      branch = add_branch
      @branches[branch.name] = branch
    end
    @git.push('origin/master', @git.target)
    @branches.each_value { |branch| merge(branch) }
  end

  def default_branch_file(branch)
    "file_#{branch.name.split('_')[-1]}"
  end

  # Build a branch with one file in it
  # NOTE: All branches have to have a common parent for more complex merges than 1-to-1
  def add_branch(branch: "branch_#{@test_char}",
                 fname: "file_#{branch.split('_')[-1]}")
    @git.reset_branch(branch, 'master', track: false)
    commit_id = add_file(branch, fname)
    @git.push(branch)
    MergeHelpers::Branch.new(branch, commit_id, @git.local_commiter_email)
  end

  def add_file(branch, fname)
    @git.checkout branch
    File.open(fname, 'w') {|f| f.write(@test_char*100);@test_char.succ!}
    commit_id = @git.add(fname, "Add #{fname}")
    if branch.is_a?(MergeHelpers::Branch)
      branch.commit_id = commit_id
      @git.push(branch.name)
    end
    commit_id
  end

  def merge(branch)
    rhs = branch.name.start_with?('conflict-') ? "origin/#{branch}" : branch.name
    _success, commit_id = @git.merge_tree('origin/staging', rhs)
    @git.update_ref('refs/remotes/origin/staging', commit_id)
    message = [branch.commiter, '', "Master: #{@git.query_rev('origin/master')}"].join("\n")
    @git.history(message, @git.current_branch_list + [branch.log])
  end

  def make_resolution_branch(branches, over_branch)
    resolver = ResolveMerge.new(logger: Logger.new(@log), git: @git, quiet: false)
    resolver.reset_test_branch(over_branch)
    success, = @git.merge(branches.map(&:commit_id), message: 'Merge branches')
    @git.commit('fix') if !success
    fix_branch_name = resolver.figure_fix_branch(over_branch, branches)
    @git.drop_branch(fix_branch_name) # to not deal with the possibility
    @git.rename_to(fix_branch_name)
    @git.push(fix_branch_name)
    @git.checkout('origin/staging_history')
    @git.drop_branch(fix_branch_name) # only remote branch should be queried
    MergeHelpers::Branch.new(fix_branch_name,
                             @git.query_rev("origin/#{fix_branch_name}"),
                             @git.local_commiter_email)
  end

  def make_conflicting_branch(origin_branch, fname: default_branch_file(origin_branch))
    branch = add_branch(fname: fname)
    fix_branch = make_resolution_branch([branch], origin_branch.name)
    [fix_branch, branch]
  end
end
