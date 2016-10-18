module Ossert
  module Fetch
    class GitHub
      attr_reader :client, :project

      extend Forwardable
      def_delegators :project, :agility, :community, :meta

      def initialize(project)
        @client = ::Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
        client.default_media_type = 'application/vnd.github.v3.star+json'
        client.auto_paginate = true

        @project = project
        raise ArgumentError unless (@repo_name = project.github_alias).present?
        @owner = @repo_name.split('/')[0]
        @requests_count = 0
      end

      # TODO:  Add github search feature
      # def find_repo(user)
      #   first_found = client.search_repos(project.name, language: :ruby, user: user)[:items].first
      #   first_found.try(:[], :full_name)
      # end

      def request(endpoint, *args)
        first_response_data = client.paginate(url(endpoint, args.shift), *args) do |_, last_response|
          last_response.data.each { |data| yield data }
        end
        first_response_data.each { |data| yield data }
      end

      def url(endpoint, repo_name)
        path = case endpoint
               when /issues_comments/
                 "issues/comments"
               when /pulls_comments/
                 "pulls/comments"
               else
                 endpoint
               end
        "#{Octokit::Repository.path repo_name}/#{path}"
      end

      def issues(&block)
        request(:issues, @repo_name, state: :all, &block)
      end

      def issues_comments(&block)
        request(:issues_comments, @repo_name, &block)
      end

      def pulls(&block)
        # fetch pull requests, identify by "url", store: "assignee", "milestone", created_at/updated_at, "user"
        # http://octokit.github.io/octokit.rb/Octokit/Client/PullRequests.html#pull_requests_comments-instance_method
        # fetch comments and link with PR by "pull_request_url"
        request(:pulls, @repo_name, state: :all, &block)
      end

      def pulls_comments(&block)
        # fetch pull requests, identify by "url", store: "assignee", "milestone", created_at/updated_at, "user"
        # http://octokit.github.io/octokit.rb/Octokit/Client/PullRequests.html#pull_requests_comments-instance_method
        # fetch comments and link with PR by "pull_request_url"
        request(:pulls_comments, @repo_name, &block)
      end

      def contributors(&block)
        request(:contributors, @repo_name, anon: true, &block)
      end

      def stargazers(&block)
        request(:stargazers, @repo_name, &block)
      end

      def watchers(&block)
        request(:subscribers, @repo_name, &block)
      end

      def forkers(&block)
        request(:forks, @repo_name, &block)
      end

      def branches(&block)
        request(:branches, @repo_name, &block)
      end

      def tags(&block)
        request(:tags, @repo_name, &block)
      end

      def last_year_commits
        last_year_commits = []
        retry_count = 3
        while last_year_commits.blank? && retry_count > 0
          last_year_commits = client.commit_activity_stats(@repo_name)
          if last_year_commits.blank?
            sleep(15*retry_count)
            retry_count -= 1
          end
        end
        last_year_commits
      end

      def top_contributors
        client.contributors_stats(@repo_name, retry_timeout: 5, retry_wait: 1)
      end

      def commit(sha)
        client.commit(@repo_name, sha)
      end

      def tag_info(sha)
        client.tag(@repo_name, sha)
      rescue Octokit::NotFound
        false
      end

      def date_from_tag(sha)
        tag_info = tag_info(sha)
        return tag_info[:tagger][:date] if tag_info
        value = commit(sha)[:commit][:committer][:date]
        DateTime.new(*value.split('-'.freeze).map(&:to_i)).to_i
      end

      def commits_since(date)
        client.commits_since(@repo_name, date)
      end

      def latest_release
        @latest_release ||= client.latest_release(@repo_name)
      end

      # Add class with processing types, e.g. top_contributors, commits and so on

      def process_top_contributors
        top_contributors.last(10).reverse.each do |c|
          login = c[:author][:login]
          (meta[:top_10_contributors] ||= []) << "https://github.com/#{login}"
        end
        nil
      end

      def process_commits
        last_year_commits.each do |week|
          current_count = agility.total.last_year_commits.to_i
          agility.total.last_year_commits = current_count + week['total']

          current_quarter_count = agility.quarters[week['week']].commits.to_i
          agility.quarters[week['week']].commits = current_quarter_count + week['total']
        end
      end

      def process_last_release_date
        latest_release_date = 0

        tags do |tag|
          tag_date = date_from_tag(tag[:commit][:sha])
          latest_release_date = [latest_release_date, tag_date].max

          agility.total.releases_total_gh << tag[:name]
          agility.quarters[tag_date].releases_total_gh << tag[:name]
        end

        unless latest_release_date.zero?
          agility.total.last_release_date = latest_release_date# wrong: last_release_commit[:commit][:committer][:date]
          agility.total.commits_count_since_last_release = commits_since(Time.at(latest_release_date)).length
        end
      end

      def process_quarters_issues_and_prs_processing_days
        issues do |issue|
          next if issue.key? :pull_request
          next unless issue[:state] == 'closed'
          next unless issue[:closed_at].present?
          days_to_close = (Date.parse(issue[:closed_at]) - Date.parse(issue[:created_at])).to_i + 1
          (agility.quarters[issue[:closed_at]].issues_processed_in_days ||= []) << days_to_close
        end

        pulls do |pull|
          next unless pull[:state] == 'closed'
          next unless pull[:closed_at].present?
          days_to_close = (Date.parse(pull[:closed_at]) - Date.parse(pull[:created_at])).to_i + 1
          (agility.quarters[pull[:closed_at]].pr_processed_in_days ||= []) << days_to_close
        end
      end

      def process_issues_and_prs_processing_days
        issues_processed_in_days = []
        issues do |issue|
          next if issue.key? :pull_request
          next unless issue[:state] == 'closed'
          next unless issue[:closed_at].present?
          days_to_close = (Date.parse(issue[:closed_at]) - Date.parse(issue[:created_at])).to_i + 1
          issues_processed_in_days << days_to_close
          (agility.quarters[issue[:closed_at]].issues_processed_in_days ||= []) << days_to_close
        end

        values = issues_processed_in_days.to_a.sort
        agility.total.issues_processed_in_avg = if values.count.odd?
                                                          values[values.count/2]
                                                        elsif values.count.zero?
                                                          0
                                                        else
                                                          ((values[values.count/2 - 1] + values[values.count/2]) / 2.0).to_i
                                                        end


        pulls_processed_in_days = []
        pulls do |pull|
          next unless pull[:state] == 'closed'
          next unless pull[:closed_at].present?
          days_to_close = (Date.parse(pull[:closed_at]) - Date.parse(pull[:created_at])).to_i + 1
          pulls_processed_in_days << days_to_close
          (agility.quarters[pull[:closed_at]].pr_processed_in_days ||= []) << days_to_close
        end

        values = pulls_processed_in_days.to_a.sort
        agility.total.pr_processed_in_avg = if values.count.odd?
                                                      values[values.count/2]
                                                    elsif values.count.zero?
                                                      0
                                                    else
                                                      ((values[values.count/2 - 1] + values[values.count/2]) / 2.0).to_i
                                                    end
      end

      def process_actual_prs_and_issues
        actual_prs, actual_issues = Set.new, Set.new
        agility.quarters.each_sorted do |quarter, data|
          data.pr_actual = actual_prs
          data.issues_actual = actual_issues

          closed = data.pr_closed + data.issues_closed
          actual_prs = (actual_prs + data.pr_open) - closed
          actual_issues = (actual_issues + data.issues_open) - closed
        end
      end

      def process_pr_with_contrib_comments_fix
        prev_prs = agility.total.pr_with_contrib_comments
        agility.total.pr_with_contrib_comments = Set.new(
          prev_prs.map { |pr_link| issue2pull_url(pr_link) }
        )
      end

      def issue2pull_url(html_url)
        html_url.gsub(
          %r{https://github.com/(#{@repo_name})/pull/(\d+)},
          'https://api.github.com/repos/\2/pulls/\3'
        )
      end

      # FIXME: delete if temporary
      def fix_issues_and_prs_with_contrib_comments
        agility.total.pr_with_contrib_comments.delete_if do |pr|
          !(pr =~ %r{https://api.github.com/repos/#{@repo_name}/pulls/\d+})
        end

        agility.total.issues_with_contrib_comments.delete_if do |issue|
          !(issue =~ %r{https://github.com/#{@repo_name}/issues/\d+})
        end
      end

      def process_pulls
        pulls_processed_in_days = []

        pulls do |pull|
          case pull[:state]
          when 'open'
            agility.total.pr_open << pull[:url]
            agility.quarters[pull[:created_at]].pr_open << pull[:url]
          when 'closed'
            agility.total.pr_closed << pull[:url]
            agility.quarters[pull[:created_at]].pr_open << pull[:url]
            agility.quarters[pull[:closed_at]].pr_closed << pull[:url] if pull[:closed_at]
            agility.quarters[pull[:merged_at]].pr_merged << pull[:url] if pull[:merged_at]
            if pull[:closed_at].present?
              days_to_close = (Date.parse(pull[:closed_at]) - Date.parse(pull[:created_at])).to_i + 1
              pulls_processed_in_days << days_to_close
              (agility.quarters[pull[:closed_at]].pr_processed_in_days ||= []) << days_to_close
            end
          end

          if pull[:user][:login] == @owner
            agility.total.pr_owner << pull[:url]
          else
            agility.total.pr_non_owner << pull[:url]
          end

          agility.total.pr_total << pull[:url]
          agility.quarters[pull[:created_at]].pr_total << pull[:url]

          if agility.total.first_pr_date.nil? || pull[:created_at] < agility.total.first_pr_date
            agility.total.first_pr_date = pull[:created_at]
          end

          if agility.total.last_pr_date.nil? || pull[:created_at] > agility.total.last_pr_date
            agility.total.last_pr_date = pull[:created_at]
          end

          community.total.users_creating_pr << pull[:user][:login]
          community.quarters[pull[:created_at]].users_creating_pr << pull[:user][:login]
          community.total.users_involved << pull[:user][:login]
          community.quarters[pull[:created_at]].users_involved << pull[:user][:login]
        end

        values = pulls_processed_in_days.to_a.sort
        agility.total.pr_processed_in_avg = if values.count.odd?
                                              values[values.count/2]
                                            elsif values.count.zero?
                                              0
                                            else
                                              ((values[values.count/2 - 1] + values[values.count/2]) / 2.0).to_i
                                            end

        pulls_comments do |pull_comment|
          login = pull_comment[:user].try(:[], :login).presence || generate_anonymous
          if community.total.contributors.include? login
            agility.total.pr_with_contrib_comments << pull_comment[:pull_request_url]
          end

          community.total.users_commenting_pr << login
          community.quarters[pull_comment[:created_at]].users_commenting_pr << login
          community.total.users_involved << login
          community.quarters[pull_comment[:created_at]].users_involved << login
        end
      end

      def process_issues
        issues_processed_in_days = []

        issues do |issue|
          next if issue.key? :pull_request
          case issue[:state]
          when 'open'
            agility.total.issues_open << issue[:url]
            agility.quarters[issue[:created_at]].issues_open << issue[:url]
          when 'closed'
            agility.total.issues_closed << issue[:url]
            # if issue is closed for now, it also was opened somewhen
            agility.quarters[issue[:created_at]].issues_open << issue[:url]
            agility.quarters[issue[:closed_at]].issues_closed << issue[:url] if issue[:closed_at]

            if issue[:closed_at].present?
              days_to_close = (Date.parse(issue[:closed_at]) - Date.parse(issue[:created_at])).to_i + 1
              issues_processed_in_days << days_to_close
              (agility.quarters[issue[:closed_at]].issues_processed_in_days ||= []) << days_to_close
            end
          end

          if issue[:user][:login] == @owner
            agility.total.issues_owner << issue[:url]
          else
            agility.total.issues_non_owner << issue[:url]
          end

          agility.total.issues_total << issue[:url]
          agility.quarters[issue[:created_at]].issues_total << issue[:url]
          if agility.total.first_issue_date.nil? || issue[:created_at] < agility.total.first_issue_date
            agility.total.first_issue_date = issue[:created_at]
          end

          if agility.total.last_issue_date.nil? || issue[:created_at] > agility.total.last_issue_date
            agility.total.last_issue_date = issue[:created_at]
          end

          community.total.users_creating_issues << issue[:user][:login]
          community.quarters[issue[:created_at]].users_creating_issues << issue[:user][:login]
          community.total.users_involved << issue[:user][:login]
          community.quarters[issue[:created_at]].users_involved << issue[:user][:login]
        end

        values = issues_processed_in_days.to_a.sort
        agility.total.issues_processed_in_avg = if values.count.odd?
                                                  values[values.count/2]
                                                elsif values.count.zero?
                                                  0
                                                else
                                                  ((values[values.count/2 - 1] + values[values.count/2]) / 2.0).to_i
                                                end

        issues_comments do |issue_comment|
          login = issue_comment[:user].try(:[], :login).presence || generate_anonymous
          issue_url = /\A(.*)#issuecomment.*\z/.match(issue_comment[:html_url])[1]
          if issue_url.include?('/pull/') # PR comments are stored as Issue comments. Sadness =(
            if community.total.contributors.include? login
              agility.total.pr_with_contrib_comments << issue2pull_url(issue_url)
            end

            community.total.users_commenting_pr << login
            community.quarters[issue_comment[:created_at]].users_commenting_pr << login
            community.total.users_involved << login
            community.quarters[issue_comment[:created_at]].users_involved << login
            next
          end

          if community.total.contributors.include? login
            agility.total.issues_with_contrib_comments << issue_url
          end

          community.total.users_commenting_issues << login
          community.quarters[issue_comment[:created_at]].users_commenting_issues << login
          community.total.users_involved << login
          community.quarters[issue_comment[:created_at]].users_involved << login
        end
      end

      def process
        contributors do |c|
          login = c.try(:[], :login).presence || generate_anonymous
          community.total.contributors << login
        end#
        community.total.users_involved.merge(community.total.contributors)

        process_issues

        process_pulls

        process_actual_prs_and_issues

        process_last_release_date

        process_commits

        process_top_contributors

        branches do |branch|
          # stale and total
          # by quarter ? date from commit -> [:commit][:committer][:date]
          # 1. save dates by commit sha.
          branch_updated_at = commit(branch[:commit][:sha])[:commit][:committer][:date]
          stale_threshold = Time.now.beginning_of_quarter

          # 2. date -> total by quarter
          #    date -> stale
          agility.total.branches << branch[:name]
          agility.total.stale_branches << branch[:name] if branch_updated_at < stale_threshold
          agility.quarters[branch_updated_at].branches << branch[:name]
        end

        stargazers do |stargazer|
          login = stargazer[:user][:login].presence || generate_anonymous
          community.total.stargazers << login
          community.total.users_involved << login

          community.quarters[stargazer[:starred_at]].stargazers << login
          community.quarters[stargazer[:starred_at]].users_involved << login
        end

        watchers do |watcher|
          login = watcher[:login].presence || generate_anonymous
          community.total.watchers << login
          community.total.users_involved << login
        end

        forkers do |forker|
          community.total.forks << forker[:owner][:login]
          community.total.users_involved << forker[:owner][:login]
          community.quarters[forker[:created_at]].forks << forker[:owner][:login]
          community.quarters[forker[:created_at]].users_involved << forker[:owner][:login]
        end
      rescue Octokit::NotFound => e
        raise "Github NotFound Error: #{e.inspect}"
      end

      # GitHub sometimes hides login, this is fallback
      def generate_anonymous
        @anonymous_count ||= 0
        @anonymous_count += 1
        "anonymous_#{@anonymous_count}"
      end
    end
  end
end
