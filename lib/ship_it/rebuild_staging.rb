#!/usr/bin/env ruby
require 'ship_it/merge_helpers'
require 'fileutils'
require 'json'

class RebuildStaging < MergeHelpers
  RETRYING_DROPPED_RESOLUTIONS = 'Retrying branches with dropped conflict resolutions'
  DEFAULTS = {quiet: true, target: 'staging', remote: 'origin', push: true}

  def self.add_options parser, options
    super
    parser.on('-f', '--force', 'Force rebuild. Useful for debugging.') do
      options[:force] = true
    end
    parser.on('-n', '--no-push', 'No push') do
      options[:push] = false
    end
    parser.on('--json', 'JSON output of bad merges') do
      options[:json] = true
    end
    parser.on('-d', '--delayed-conflict-drop', 'Delay dropping conflicts with branches merged to master by one rebuild') do
      options[:delayed_conflict_drop] = true
    end
  end

  def target_test_branch
    @target_test_branch ||= "predeploy_#{@git.target}"
  end

  def process
    load_branch_lists
    setup_extra_data
    if !(@force_rebuild || new_branches? || removed_branches?)
      raise "#{@git.target} based on current master and no additions/removals requested, rebuild not required."
    end

    setup_test_branch
    add_new_branches
    report_bad_branches
    publish
  end

  # Override to allow for :delayed_conflict_drop
  def missing_parts?(branch, all_branches)
    parts = branch.conflict_branches - all_branches
    return [] if (parts & @new_branches.keys) == parts
    @logger.debug "Missing for #{branch}: #{parts}" if parts.any?
    if @options[:delayed_conflict_drop]
      delayed_drops = parts & @branches_in_master.map(&:name)
      if delayed_drops.any?
        branch.reason = delayed_drops.join(', ')
        collect_bad_branches([branch], 'In master - will be dropped next deploy')
      end
      parts - delayed_drops
    else
      parts
    end
  end

  def load_branch_lists
    load_branches
    @new_branches = BranchList.read('new_branches.list').map {|branch_data| Branch.new(*branch_data)}
    @new_branches -= @branches # no clones, please
    @resolution_branches = {}
    @new_branches = @new_branches.reduce({}) do |hash, branch|
      hash[branch.name] = branch
      hash
    end
    @removed_branches = BranchList.read('removed_branches.list').map {|branch_data| Branch.new(*branch_data)}
    if @removed_branches.map(&:name) == ['all']
      @removed_branches = @branches
      @force_rebuild = true
    end
  end

  def setup_extra_data
    master_changed = !@git.branch_in?("#{@git.remote}/master", "#{@git.remote}/#{@git.target}")
    @force_rebuild ||= @options[:force] || master_changed
    @old_branches = @branches
    @bad_branches = []
    @branches_in_master = @branches.select do |branch|
      @git.branch_in?(branch.commit_id, "#{@git.remote}/master")
    end
    @logger.debug "In master: #{@branches_in_master.map(&:name)}"
    gone_branches = @branches.select do |branch|
      @logger.info "Checking #{branch.name}"
      !@git.query_rev_name("#{@git.remote}/#{branch.name}")
    end
    @branches -= gone_branches
    @logger.info "Disappeared: #{gone_branches.map(&:name)}"
    @failed_report = {}
  end

  # Filter out the new/removed branches request lists from the "original"
  # branches list.
  # Branches that are already in master will be filtered out later,
  # both to collect resolutions against branches already merged to master
  # and to get a nice log.
  def branches_without_change_requests
    branches = @branches - @removed_branches
    branches.delete_if { |branch| @new_branches.key?(branch.name) }
    base_branch_names = branches.reject(&:resolution?).map(&:name)
    resolution_uses = branches.each_with_object(Hash.new(0)) do |branch, hash|
      next unless branch.resolution? && (base_branch_names & branch.conflict_branches).any?
      branch.conflict_branches.each do |mbranch|
        hash[mbranch] += 1
      end
    end

    branches.delete_if do |branch|
      missing_branches = branch.conflict_branches - base_branch_names
      next unless missing_branches.any?
      if missing_branches == missing_branches & @new_branches.keys
        present = branch.conflict_branches - missing_branches
        updated_depends = missing_branches.map { |mbranch| resolution_uses[mbranch] }.max
        present_depends = present.map { |mbranch| resolution_uses[mbranch] }.max
        next if present_depends > updated_depends # present branches require the resolution
      end

      build_resolution_branch(branch)
      true
    end
  end

  # Will rebuild to spec if:
  # - forced
  # - new master
  # - branches already in the target have update requests
  def setup_test_branch
    branches = branches_without_change_requests
    if @force_rebuild || @old_branches.size > branches.size
      @branches = branches
      @logger.info "Rebuilding #{@git.target}"
      reset_test_branch("#{@git.remote}/master")
      @branches, bad_branches, _skipped_resolutions =
        mass_merge(branches, current_branches: @branches - @branches_in_master)
      collect_bad_branches bad_branches, 'Conflicted with master'
    else
      reset_test_branch("#{@git.remote}/#{@git.target}")
    end
  end

  def add_new_branches
    return unless new_branches?

    @logger.info 'Adding new branches'
    branches = @new_branches.values.flat_map do |branch|
      branch_list = branch.conflict_or_normal_branches
      old_res_list = branch_list.map {|branch_name| @resolution_branches[branch_name]}.compact.flatten(1).uniq
      old_res_list.sort_by { |b| -b.name.length } + [branch]
    end
    new_branches, bad_branches, _skipped_resolutions = mass_merge(branches)
    @branches += new_branches
    collect_bad_branches bad_branches, "Conflicted with #{@git.target}"
  end

  def publish
    if @force_rebuild || @old_branches != @branches
      if @options[:push]
        @git.drop_remote target_test_branch
        @git.push MERGE_TEST_BRANCH, target_test_branch
        publish_changes
      else
        @logger.info 'Leaving locally'
      end
      @logger.info 'Done rebuilding'
    else
      raise "No changes made to #{@git.target} - rebuild failed"
    end
  end

  def build_resolution_branch branch
    conflict_list = branch.conflict_branches
    conflict_list.each do |mbranch|
      (@resolution_branches[mbranch] ||= []) << branch
    end
  end

  def new_branches?
    @new_branches.size > 0
  end

  def removed_branches?
    @removed_branches.size > 0
  end

  def publish_changes
    message = [current_commiter, '', "Master: #{@git.query_rev("#{@git.remote}/master")}"]
    message[0] += " - FORCED" if @options[:force]
    @git.history(message.join("\n"), @branches.map(&:log))
  end

  def collect_bad_branches bad_branches, subject
    return if bad_branches.empty?
    bad_branches.each do |branch|
      list = (@failed_report[branch.commiter] ||= {})[subject] ||= []
      list << branch.dump
    end
  end

  def report_bad_branches
    @failed_report.each do |_commiter, subjects|
      subjects.each do |_subject, list|
        list.uniq!
      end
    end
    if @options[:json]
      json_report
    else
      output_report
    end
  end

  def json_report
    FileUtils.rm_f('failed_report.json')
    return if @failed_report.empty?
    File.open('failed_report.json', 'w') do |f|
      f.write(JSON.dump(@failed_report))
    end
  end

  def output_report
    @failed_report.each do |commiter, causes|
      causes.each do |cause, list|
        @logger.error "#{commiter} - #{cause}"
        list.each do |issue|
          @logger.error "- #{issue[:branch]}(#{issue[:commit_id]}): #{issue[:reason]}"
        end
      end
    end
  end
end
