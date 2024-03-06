require 'logger'
require 'tempfile'
require 'shellwords'
require 'ship_it/branch_list'

# Git wrapper utility
class GitActions
  attr_reader :history_branch, :logger, :remote, :target

  class Exception < ::StandardError
  end

  # Bundler's special parameter for "nothing to do"
  BUNDLER_NIL = 'BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL'

  def initialize(target = 'staging', remote = 'origin', push_remote = remote)
    @remote = (remote || 'origin').freeze
    @push_remote = (push_remote || remote).freeze
    @target = (target || 'staging').freeze
    @starting_branch = nil
    @history_branch = "#{target}_history".freeze
    @last_merge_failed = nil
    set_logger Logger.new(STDOUT)
  end

  def set_logger logger
    @logger = logger
  end

  def init_repo
    git %W'init .'
    init_history_branch
  end

  def starting_branch
    if @starting_branch
      return @starting_branch
    else
      @starting_branch = git(%W'rev-parse --abbrev-ref HEAD')
      if @starting_branch == 'HEAD'
        @starting_branch = query_rev('HEAD')
      end
      @starting_branch
    end
  end

  def reset_state
    clear_merges
    checkout starting_branch
  end

  def merging?
    File.exist?('.git/MERGE_HEAD') ? 'Merging!' : false
  end

  def unclean?
    modified_files = get_modified_files
    files = modified_files.size > 0 ? modified_files : false
    files || merging?
  end

  def get_modified_files
    git(%W"status --porcelain").each_line.map {|l| s, file = l.split(' '); s != '??' ? file : nil}.compact
  end

  def sync_to_origin
    git('fetch')
    reset_branch @history_branch, "#{@remote}/#{@history_branch}"
  end

  def merge(branches, message: nil)
    status, output = git(['merge', ("-m#{message}" if message), '--no-ff', *branches].compact, forward_failure: true)
    raise output if status.exitstatus == 128 # untracked files messing up the merge
    @last_merge_failed = !status.success?
    [status.success?, output]
  end

  def clear_merges
    if @last_merge_failed
      @logger.debug 'Clearing merge'
      git(%W"reset --merge")
      @last_merge_failed = !$?.success?
    end
  end

  def rename_to new_name
    git(%W"branch -m #{new_name}", forward_failure: true)
    #[$?.success?, output]
  end

  def init_history_branch
    write_history_branch('initial .branches.list', [], true)
  end

  def history message, branches
    write_history_branch(message, branches)
    push @history_branch
  end

  def write_history_branch message, branches, reset_branch = false
    file = Tempfile.new('.branches.list')
    file.write(BranchList.dump(branches))
    file.close
    write_commit(@history_branch, message, {'.branches.list' => file.path}, origin: reset_branch ? nil : @history_branch)
    file.unlink
  end

  def current_branch_list
    BranchList.parse git(%W'show #{@history_branch}:.branches.list')
  end

  def local_commiter_email
    git(%W"config --get user.email")
  end

  def local_commiter_name
    git(%W"config --get user.name")
  end

  def reset_branch branch, source, track: true
    track = track ? nil : '--no-track'
    git(['branch', '-f', track, branch, source].compact)
  end

  def checkout branch
    git(%W"checkout -q #{branch}")
  end

  def push branch, remote_branch=branch
    git(%W"push -f #{@push_remote} #{branch}:refs/heads/#{remote_branch}")
  end

  def drop_branch branch
    git(%W"branch -D #{branch}", forward_failure: true)
  end

  def drop_remote branch
    git(%W"push #{@push_remote} :#{branch}", forward_failure: true) # Ignore failure - already dropped
  end

  def query_rev reference
    git(%W"log -1 --pretty=format:%H #{reference}")
  end

  def search_ref(is_remote)
    ref = is_remote ? "refs/remotes/#{@remote}" : 'refs/heads'
    "#{ref}/*"
  end

  def query_rev_name(revision, is_remote: revision.start_with?("#{@remote}/"))
    _status, newrev = git(%W"name-rev --name-only --refs #{search_ref(is_remote)} --no-undefined #{revision}", forward_failure: true)

    if newrev.empty? || newrev.include?('cannot describe') || newrev.start_with?('Could not get sha1')
      @logger.info "Unable to resolve branch for #{revision}"
      return
    end
    return newrev.split('/')[-1].split('shipit-')[-1].split('~')[0].split('^')[0]
  end

  def branch_in?(rev, containing_rev)
    status, list = git(%W"rev-list #{containing_rev}..#{rev}", forward_failure: true, no_err: true)
    answer = status.success? && list.empty?
    @logger.debug { "Branch #{rev} in #{containing_rev}? #{answer}" }
    answer
  end

  def commit(message)
    git %W"commit --no-verify -am #{message}"
  end

  def add(path, message)
    git %W"add #{path}"
    commit(message)
    query_rev('HEAD')
  end

  # Rewrite a branch edge with the given tree structure without switching branches
  #
  # file_map: a hash from the file names in the commit and the real file paths
  # This is especially useful for temporary files you don't want to keep around
  # origin: If an origin is not defined, this will reset the branch to begin
  # with the newly created commit
  def write_commit(branch, message, file_map, origin: branch)
    file_hashes = file_map.reduce({}) do |fh, (commit_path, real_path)|
      fh[commit_path] = git(%W"hash-object -w #{real_path}")
      fh
    end
    branch_file = Tempfile.new('branches.tree')
    file_hashes.each do |commit_path, sha1|
      branch_file.puts "100644 blob #{sha1}\t#{commit_path}"
    end
    branch_file.close
    message_file = Tempfile.new('branches.message')
    message_file.puts message
    message_file.close
    sha1 = git('mktree', input: branch_file.path)
    with_history = origin ? %W" -p #{origin}" : []
    sha1 = git(%W"commit-tree #{sha1}" + with_history, input: message_file.path)
    [branch_file, message_file].each(&:unlink)
    git(%W"update-ref refs/heads/#{branch} #{sha1}")
    sha1
  end

  private

  def git(args, forward_failure: false, input: nil, no_err: false)
    command_array = ['git'] + Array(args)
    logger.debug "Command: %s" % command_array.shelljoin
    options = {}
    options.merge!(no_err ? {err: '/dev/null'} : {err: [:child,:out]})
    if input
      options.merge!(in: input)
    end
    bundler_rubyopt = ENV['BUNDLER_ORIG_RUBYOPT']
    bundler_rubyopt = nil if bundler_rubyopt == BUNDLER_NIL
    env = ENV.to_h.merge('RUBYOPT' => bundler_rubyopt)
    output = IO.popen(env, command_array.push(options)){|io| io.read }
    if $?.success? || forward_failure
      forward_failure ? [$?, output.strip] : output.strip
    else
      raise Exception, "For command #{command_array.shelljoin}: #{output}"
    end
  end
end
