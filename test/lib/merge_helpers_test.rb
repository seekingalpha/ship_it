require 'test_helper'
require 'ship_it/merge_helpers'

class MergeHelpersTest < RepoTest
  def setup
    super
    @merge_helpers = MergeHelpers.new
  end

  def test_rename_with_override
    one_file_branch('master', 'one_file', 'stuff on master')
    one_file_branch('muster', 'one_file', 'stuff on muster')
    assert_equal 'muster', @merge_helpers.rename_branch('muster', force: true)
  end

  def test_rename_to_other
    one_file_branch('master', 'one_file', 'stuff on master')
    one_file_branch('muster', 'one_file', 'stuff on muster')
    assert_equal 'muster1', @merge_helpers.rename_branch('muster')
  end

  def one_file_branch bname, fname, content
    temp_file('some_file', content) do |file|
      @git.write_commit(bname, "a #{bname} commit", {fname => file.path}, origin: nil)
    end
  end
end
