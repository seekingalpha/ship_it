require 'test_helper'

# Tests rely on the fact that the master branch is auto-checked on creation
# when there is no current branch yet

class GitActionsTest < ShipItTest
  def setup
    super
    @git = GitActions.new
    @git.set_logger Logger.new('/dev/null')
    @git.init_repo
    temp_file('initial_file', 'random file') do |file|
      @git.write_commit('init_branch', "an initial commit", {'initial file' => file.path}, origin: nil)
    end
  end

  def test_will_write_staging_history
    assert_equal [], @git.current_branch_list
    history = [['master', 'somesha1', @git.local_commiter_email]]
    @git.history('adding master O_o', history)
    assert_equal history, @git.current_branch_list
    @git.history('zero changes', [])
    assert_equal [], @git.current_branch_list
  end

  def test_will_merge_branches
    one_file_branch('master', 'one_file', 'stuff on master')
    one_file_branch('muster', 'another_file', 'stuff on muster')
    @git.checkout('master')
    assert(*@git.merge('muster'))
  end

  def test_will_not_merge_conflicts
    one_file_branch('master', 'one_file', 'stuff on master')
    one_file_branch('muster', 'one_file', 'stuff on muster')
    @git.checkout('master')
    refute(*@git.merge('muster'))
  end

  def test_rename
    one_file_branch('master', 'one_file', 'stuff on master')
    @git.rename_to 'muster'
    assert_equal 'muster', @git.query_rev_name('HEAD')
    refute @git.query_rev_name('master')
  end

  def test_rename_failure
    one_file_branch('master', 'one_file', 'stuff on master')
    one_file_branch('muster', 'one_file', 'stuff on muster')
    refute @git.rename_to('muster')[0].success?
  end

  def one_file_branch(bname, fname, content)
    temp_file('some_file', content) do |file|
      @git.write_commit(bname, "a #{bname} commit", { fname => file.path }, origin: 'init_branch')
    end
  end
end
