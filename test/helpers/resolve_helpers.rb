module ResolveHelpers
  class CancelError < RuntimeError
  end

  def after_setup
    @log = StringIO.new
    @resolver = ResolveMerge.new(logger: Logger.new(@log), git: @git, quiet: false)
  end

  def flush_log
    @log.truncate(0)
    @log.rewind
  end

  def resolve_merge branches
    @resolver.set_new_branches(Array(branches)).run
  end

  def resolve_merge_without_user_request branch, indirection_offset=0
    request_user_replacement = ->{raise CancelError, 'User input requested'}
    $stdin.stub(:gets, request_user_replacement) do
      resolve_merge(branch)
    end
  rescue StandardError => e # add real error location
    if e.message.include?('CancelError')
      raise MiniTest::Assertion, "Called from #{caller[1+indirection_offset]}\n#{e}\n#{@log.string}", e.backtrace
    elsif e.message.include?('GitActions::Exception')
      raise e.class, e.message, e.backtrace.delete_if {|l| l.include?('/gems/')}
    else
      raise
    end
  end

  def resolve_merge_with_resolution_request branches, indirection_offset=0
    branches = [branches].flatten(1).map(&:name)
    request_user_replacement = ->{}
    request_user_replacement = ->{
      if @log.string.end_with?(ResolveMerge::RESOLVE_REQUEST)
        @git.commit('bad merge')
      elsif @log.string.end_with?(ResolveMerge::USAGE_QUERY)
        raise CancelError, "Resolution branch usage requested"
      else
        raise CancelError, "Unknown request! #{@log.string.lines.last}"
      end
    }
    $stdout.stub(:print, ->(string) {@log.print string}) do
      $stdin.stub(:gets, request_user_replacement) do
        resolve_merge(branches)
      end
    end
    assert_includes @log.string, ResolveMerge::RESOLVE_REQUEST
  rescue Minitest::Assertion, StandardError # add real error location
    raise $!.class, "Called from #{caller[1+indirection_offset]}\n#{$!}", $!.backtrace
  end

  def resolve_merge_with_usage_request branches, indirection_offset=0
    branches = [branches].flatten(1).map(&:name)
    request_user_replacement = ->{
      if @log.string.end_with?(ResolveMerge::RESOLVE_REQUEST)
        raise CancelError, 'Conflict resolution requested'
      elsif @log.string.end_with?(ResolveMerge::USAGE_QUERY)
        'Yes'
      else
        raise CancelError, "Unknown request! #{@log.string.lines.last}"
      end
    }
    $stdout.stub(:print, ->(string) {@log.print string}) do
      $stdin.stub(:gets, request_user_replacement) do
        resolve_merge(branches)
      end
    end
  rescue Minitest::Assertion, StandardError # add real error location
    puts @log.string
    raise $!.class, "Called from #{caller[1+indirection_offset]}\n#{$!}", $!.backtrace
  end
end
