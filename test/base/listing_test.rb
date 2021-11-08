require 'test_helper'
require 'ship_it/branch_list'

class ListingTest < ShipItTest
  def test_can_work_with_branch_lists
    list = 'a'.upto('c').map {|name| ["#{name}_branch", name*40, 'tester']}
    assert_equal list, BranchList.parse(BranchList.dump(list+list))
    BranchList.write('test.list', list)
    assert_equal list, BranchList.read('test.list')
  end
end
