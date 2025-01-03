# This script is based on commands from the wiki:
# https://github.com/ruby/spec/wiki/Merging-specs-from-JRuby-and-other-sources

IMPLS = {
  truffleruby: {
    git: "https://github.com/oracle/truffleruby.git",
    from_commit: "f10ab6988d",
  },
  jruby: {
    git: "https://github.com/jruby/jruby.git",
    from_commit: "f10ab6988d",
  },
  rbx: {
    git: "https://github.com/rubinius/rubinius.git",
  },
  mri: {
    git: "https://github.com/ruby/ruby.git",
  },
}

MSPEC = ARGV.delete('--mspec')

CHECK_LAST_MERGE = !MSPEC && ENV['CHECK_LAST_MERGE'] != 'false'
TEST_MASTER = ENV['TEST_MASTER'] != 'false'

ONLY_FILTER = ENV['ONLY_FILTER'] == 'true'

MSPEC_REPO = File.expand_path("../../..", __FILE__)
raise MSPEC_REPO if !Dir.exist?(MSPEC_REPO) or !Dir.exist?("#{MSPEC_REPO}/.git")

# Assuming the rubyspec repo is a sibling of the mspec repo
RUBYSPEC_REPO = File.expand_path("../rubyspec", MSPEC_REPO)
raise RUBYSPEC_REPO unless Dir.exist?(RUBYSPEC_REPO)

SOURCE_REPO = MSPEC ? MSPEC_REPO : RUBYSPEC_REPO

NOW = Time.now

BRIGHT_RED = "\e[31;1m"
BRIGHT_YELLOW = "\e[33;1m"
RESET = "\e[0m"

# git filter-branch --subdirectory-filter works fine for our use case
ENV['FILTER_BRANCH_SQUELCH_WARNING'] = '1'

class RubyImplementation
  attr_reader :name

  def initialize(name, data)
    @name = name.to_s
    @data = data
  end

  def git_url
    @data[:git]
  end

  def repo_name
    File.basename(git_url, ".git")
  end

  def repo_path
    "#{__dir__}/#{repo_name}"
  end

  def repo_org
    File.basename(File.dirname(git_url))
  end

  def from_commit
    from = @data[:from_commit]
    "#{from}..." if from
  end

  def last_merge_message
    message = @data[:merge_message] || "Update to ruby/spec@"
    message.gsub!("ruby/spec", "ruby/mspec") if MSPEC
    message
  end

  def prefix
    MSPEC ? "spec/mspec" : "spec/ruby"
  end

  def rebased_branch
    "#{@name}-rebased"
  end
end

def sh(*args)
  puts args.join(' ')
  system(*args)
  raise unless $?.success?
end

def branch?(name)
  branches = `git branch`.sub('*', '').lines.map(&:strip)
  branches.include?(name)
end

def update_repo(impl)
  unless File.directory? impl.repo_name
    sh "git", "clone", impl.git_url
  end

  Dir.chdir(impl.repo_name) do
    puts Dir.pwd

    sh "git", "checkout", "master"
    sh "git", "pull"
  end
end

def filter_commits(impl)
  Dir.chdir(impl.repo_name) do
    date = NOW.strftime("%F")
    branch = "#{MSPEC ? :mspec : :specs}-#{date}"

    unless branch?(branch)
      sh "git", "checkout", "-b", branch
      sh "git", "filter-branch", "-f", "--subdirectory-filter", impl.prefix, *impl.from_commit
      sh "git", "push", "-f", SOURCE_REPO, "#{branch}:#{impl.name}"
    end
  end
end

def rebase_commits(impl)
  Dir.chdir(SOURCE_REPO) do
    sh "git", "checkout", "master"
    sh "git", "pull"

    rebased = impl.rebased_branch
    if branch?(rebased)
      last_commit = Time.at(Integer(`git log -n 1 --format='%ct' #{rebased}`))
      days_since_last_commit = (NOW-last_commit) / 86400
      if days_since_last_commit > 7
        abort "#{BRIGHT_RED}#{rebased} exists but last commit is old (#{last_commit}), delete the branch if it was merged#{RESET}"
      else
        puts "#{BRIGHT_YELLOW}#{rebased} already exists, last commit on #{last_commit}, assuming it correct#{RESET}"
        sh "git", "checkout", rebased
      end
    else
      sh "git", "checkout", impl.name

      if ENV["LAST_MERGE"]
        last_merge = `git log -n 1 --format='%H %ct' #{ENV["LAST_MERGE"]}`
      else
        last_merge = `git log --grep='^#{impl.last_merge_message}' -n 1 --format='%H %ct'`
      end
      last_merge, commit_timestamp = last_merge.split(' ')

      raise "Could not find last merge" unless last_merge
      puts "Last merge is #{last_merge}"

      commit_date = Time.at(Integer(commit_timestamp))
      days_since_last_merge = (NOW-commit_date) / 86400
      if CHECK_LAST_MERGE and days_since_last_merge > 60
        raise "#{days_since_last_merge.floor} days since last merge, probably wrong commit"
      end

      puts "Checking if the last merge is consistent with upstream files"
      rubyspec_commit = `git log -n 1 --format='%s' #{last_merge}`.chomp.split('@', 2)[-1]
      sh "git", "checkout", last_merge
      sh "git", "diff", "--exit-code", rubyspec_commit, "--", ":!.github"

      puts "Rebasing..."
      sh "git", "branch", "-D", rebased if branch?(rebased)
      sh "git", "checkout", "-b", rebased, impl.name
      sh "git", "rebase", "--onto", "master", last_merge
    end
  end
end

def new_commits?(impl)
  Dir.chdir(SOURCE_REPO) do
    diff = `git diff master #{impl.rebased_branch}`
    !diff.empty?
  end
end

def test_new_specs
  require "yaml"
  Dir.chdir(SOURCE_REPO) do
    workflow = YAML.load_file(".github/workflows/ci.yml")
    job_name = MSPEC ? "test" : "specs"
    versions = workflow.dig("jobs", job_name, "strategy", "matrix", "ruby")
    versions = versions.grep(/^\d+\./) # Test on MRI
    min_version, max_version = versions.minmax

    test_command = MSPEC ? "bundle install && bundle exec rspec" : "../mspec/bin/mspec -j"

    run_test = -> version {
      command = "chruby #{version} && #{test_command}"
      sh ENV["SHELL"], "-c", command
    }

    run_test[min_version]
    run_test[max_version]
    run_test["ruby-master"] if TEST_MASTER
  end
end

def verify_commits(impl)
  puts
  Dir.chdir(SOURCE_REPO) do
    puts "Manually check commit messages:"
    print "Press enter >"
    STDIN.gets
    system "git", "log", "master..."
  end
end

def fast_forward_master(impl)
  Dir.chdir(SOURCE_REPO) do
    sh "git", "checkout", "master"
    sh "git", "merge", "--ff-only", impl.rebased_branch
    sh "git", "branch", "--delete", impl.rebased_branch
  end
end

def check_ci
  puts
  puts <<-EOS
  Push to master, and check that the CI passes:
    https://github.com/ruby/#{:m if MSPEC}spec/commits/master

  EOS
end

def main(impls)
  impls.each_pair do |impl, data|
    impl = RubyImplementation.new(impl, data)
    update_repo(impl)
    filter_commits(impl)
    unless ONLY_FILTER
      rebase_commits(impl)
      if new_commits?(impl)
        test_new_specs
        verify_commits(impl)
        fast_forward_master(impl)
        check_ci
      else
        STDERR.puts "#{BRIGHT_YELLOW}No new commits#{RESET}"
        fast_forward_master(impl)
      end
    end
  end
end

if ARGV == ["all"]
  impls = IMPLS
else
  args = ARGV.map { |arg| arg.to_sym }
  raise ARGV.to_s unless (args - IMPLS.keys).empty?
  impls = IMPLS.select { |impl| args.include?(impl) }
end

main(impls)
