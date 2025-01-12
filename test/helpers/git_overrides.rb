require 'ship_it/merge_helpers'

class GitActions
  undef_method :sync_to_origin
  def sync_to_origin; end

  undef_method :push
  def push(branch, remote_branch = branch)
    update_ref("refs/remotes/#{@remote}/#{remote_branch}", branch)
  end

  undef_method :drop_remote
  def drop_remote(branch)
    git(%W[branch -D #{@remote}/#{branch}], forward_failure: true)
  end
end
