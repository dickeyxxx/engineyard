require 'thor'

module EY
  module UtilityMethods
    protected
    def api
      @api ||= load_api
    end

    def load_api
      api = EY::CLI::API.new(EY.config.endpoint)
      api.current_user # check login and access to the api
      api
    rescue EY::CloudClient::InvalidCredentials
      EY::CLI::API.authenticate
      retry
    end

    def repo
      @repo ||= EY::Repo.new
    end

    def fetch_environment(environment_name, account_name)
      environment_name ||= EY.config.default_environment
      remotes = repo.remotes if repo.exist?
      constraints = {
        :environment_name => environment_name,
        :account_name     => account_name,
        :remotes          => remotes,
      }
      environments = api.resolve_environments(constraints)

      case environments.size
      when 0 then
        if environment_name
          raise EY::CloudClient::NoEnvironmentError.new(environment_name, EY::CloudClient.endpoint)
        else
          raise EY::CloudClient::NoAppError.new(repo, EY::CloudClient.endpoint)
        end
      when 1 then environments.first
      else
        if environment_name
          message = "Multiple environments possible, please be more specific:\n\n"
          environments.each do |env|
            message << "\t#{env.name.ljust(25)} # ey <command> --environment='#{env.name}' --account='#{env.account.name}'\n"
          end
          raise EY::CloudClient::MultipleMatchesError.new(message)
        else
          raise EY::CloudClient::AmbiguousEnvironmentGitUriError.new(environments)
        end
      end
    end

    def fetch_app_environment(app_name, environment_name, account_name)
      environment_name ||= EY.config.default_environment
      remotes = repo.remotes if repo.exist?
      constraints = {
        :app_name         => app_name,
        :environment_name => environment_name,
        :account_name     => account_name,
        :remotes          => remotes,
      }

      if constraints.all? { |k,v| v.nil? || v.empty? || v.to_s.empty? }
        raise EY::CloudClient::NoMatchesError.new <<-ERROR
Unable to find application without a git remote URI or app name.

Please specify --app app_name or add this application at #{EY::CloudClient.endpoint}"
        ERROR
      end

      app_envs = api.resolve_app_environment(constraints)

      case app_envs.size
      when 0 then raise EY::CloudClient::NoMatchesError.new(no_app_environments_error(constraints))
      when 1 then app_envs.first
      else        raise EY::CloudClient::MultipleMatchesError.new(too_many_app_environments_error(app_envs))
      end
    end

      def no_app_environments_error(constraints)
        if constraints[:account_name] && account_candidates(constraints).empty?
          # Account specified doesn't exist
          "No account found matching #{constraints[:account_name].inspect}."
        elsif app_candidates(constraints).empty?
          # App not found
          if constraints[:app_name]
            # Specified app not found
            #EY::CloudClient::InvalidAppError.new(constraints[:app_name])
            "No application found matching #{constraints[:app_name].inspect}."
          else
            # Repository not found
            return <<-ERROR
No application configured for any of the following remotes:
\t#{constraints[:remotes].join("\n\t")}
You can add this application at #{EY::CloudClient.endpoint}.
            ERROR
          end
        elsif filter_if_constrained(constraints,:environment_name, all).empty?
          # Environment doesn't exist
          "No environment found matching #{constraints[:environment_name].inspect}."
        elsif constraints[:account_name] && environment_candidates_matching_account(constraints).empty?
          # Environment not found under this account
          "Environment matching #{constraints[:environment_name].inspect} exists on a different account."
        else
          # Account, app, and/or environment found, but don't match
          message = "The matched apps & environments do not correspond with each other.\n"
          message << "Applications:\n"

          ### resolver.apps belongs here.

          app_candidates(constraints).uniq {|app_env| [app_env.account_name, app_env.app_name] }.each do |app_env|
            app = app_env.app
            message << "\t#{app.account.name}/#{app.name}\n"
            app.environments.each do |env|
              message << "\t\t#{env.name} # ey <command> -e #{env.name} -a #{app.name}\n"
            end
          end

          message
        end
      end

      def too_many_app_environments_error(app_envs)
        message = "Multiple application environments possible, please be more specific:\n\n"

        app_envs.group_by do |app_env|
          "#{app_env.account_name}/#{app_env.app_name}"
        end.each do |account_app_name, grouped_app_envs|
          message << account_app_name << "\n"
          grouped_app_envs.sort_by { |ae| ae.environment_name }.each do |app_env|
            message << "\t#{app_env.environment_name.ljust(25)}"
            message << " # ey <command> --account='#{app_env.account_name}' --app='#{app_env.app_name}' --environment='#{app_env.environment_name}'\n"
          end
        end
        EY::CloudClient::MultipleMatchesError.new(message)
      end

      def account_candidates(constraints)
        @account_candidates ||= filter_if_constrained(constraints, :account_name) || all
      end

      def app_candidates(constraints)
        @app_candidates ||= filter_if_constrained(constraints, :app_name, account_candidates(constraints)) || app_candidates_matching_repo(constraints) || all
      end

      # first, find only environments
      def environment_candidates(constraints)
        @environment_candidates ||=
          environment_candidates_matching_app(constraints) ||
          environment_candidates_matching_account(constraints) ||
          filter_if_constrained(constraints,:environment_name, all) ||
          all
      end

      def all
        @all ||= api.app_environments
      end

      # Returns matches that also match the app if we've be able to narrow by app_candidate.
      def environment_candidates_matching_app(constraints)
        if !app_candidates.empty? && app_candidates.size < all.size
          filter_if_constrained(constraints,:environment_name, app_candidates)
        end
      end

      def environment_candidates_matching_account(constraints)
        if !account_candidates(constraints).empty? && account_candidates(constraints).size < all.size
          filter_if_constrained(constraints,:environment_name, account_candidates(constraints))
        end
      end

      # find by repository uri
      # if none match, return nil
      def app_candidates_matching_repo(constraints)
        filter(account_candidates(constraints)) {|app_env| repo && repo.has_remote?(app_env.repository_uri) }
      end

      # If the constraint is set, the only return matches
      # if it is not set, then return all matches
      # returns exact matches, then partial matches, then all
      def filter_if_constrained(constraints, key, app_env_set = all)
        return unless constraints[key]

        match = constraints[key].downcase

        exact_match   = lambda {|app_env| app_env.send(key) == match }
        partial_match = lambda {|app_env| app_env.send(key).index(match) }

        filter(app_env_set, &exact_match) || filter(app_env_set, &partial_match) || []
      end

      # returns nil if no matches
      # returns an array of matches if any match
      def filter(app_env_set = all, &block)
        matches = app_env_set.select(&block)
        matches.empty? ? nil : matches
      end

  end # UtilityMethods

  class Thor < ::Thor
    include UtilityMethods

    check_unknown_options!

    no_tasks do
      def self.subcommand_help(cmd)
        desc "#{cmd} help [COMMAND]", "Describe all subcommands or one specific subcommand."
        class_eval <<-RUBY
          def help(*args)
            if args.empty?
              EY.ui.say "usage: #{banner_base} #{cmd} COMMAND"
              EY.ui.say
              subcommands = self.class.printable_tasks.sort_by{|s| s[0] }
              subcommands.reject!{|t| t[0] =~ /#{cmd} help$/}
              EY.ui.print_help(subcommands)
              EY.ui.say self.class.send(:class_options_help, EY.ui)
              EY.ui.say "See #{banner_base} #{cmd} help COMMAND" +
                " for more information on a specific subcommand." if args.empty?
            else
              super
            end
          end
        RUBY
      end

      def self.banner_base
        "ey"
      end

      def self.banner(task, task_help = false, subcommand = false)
        subcommand_banner = to_s.split(/::/).map{|s| s.downcase}[2..-1]
        subcommand_banner = if subcommand_banner.size > 0
                              subcommand_banner.join(' ')
                            else
                              nil
                            end

        task = (task_help ? task.formatted_usage(self, false, subcommand) : task.name)
        [banner_base, subcommand_banner, task].compact.join(" ")
      end

      def self.handle_no_task_error(task)
        raise UndefinedTaskError, "Could not find command #{task.inspect}."
      end

      def self.subcommand(name, klass)
        @@subcommand_class_for ||= {}
        @@subcommand_class_for[name] = klass
        super
      end

      def self.subcommand_class_for(name)
        @@subcommand_class_for ||= {}
        @@subcommand_class_for[name]
      end

    end

    protected

    def self.exit_on_failure?
      true
    end

  end
end
