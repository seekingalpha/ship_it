require 'ship_it/merge_helpers'

class GitActions
  undef_method :sync_to_origin
  def sync_to_origin; end

  undef_method :push
  def push(branch, remote_branch = branch)
    reset_branch("#{@remote}/#{remote_branch}", branch, track: false)
  end

  undef_method :search_ref
  def search_ref(is_remote)
    ref = is_remote ? "refs/heads/#{@remote}" : 'refs/heads'
    "#{ref}/*"
  end

  undef_method :drop_remote
  def drop_remote(branch)
    git(%W[branch -D #{@remote}/#{branch}], forward_failure: true)
  end
end

class MergeHelpers
  undef_method :raise_if_no_history_branch
  def raise_if_no_history_branch
    return if @git.query_rev_name("#{@git.remote}/#{@git.history_branch}", is_remote: false)

    raise %(History branch for #{@git.target} is missing! Run rake shipit:history_branch[#{@git.target}] to create it.)
  end
end
