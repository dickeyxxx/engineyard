require 'engineyard-api-client/errors'

module EY
  class APIClient
    class Resolver
      attr_reader :api, :constraints

      def initialize(api, constraints)
        if constraints.empty?
          raise ArgumentError, "Expected Resolver filtering constraints, got: #{constraints.inspect}"
        end
        @api = api
        @constraints = constraints
      end

      def environment
        if constraints[:app_name]
          raise ArgumentError, "Unexpected option :app_name for Resolver#environment."
        end

        account_and_environment_names = candidates.map { |app_env| [app_env.account_name, app_env.environment_name] }.uniq

        environments = account_and_environment_names.map do |account_name, environment_name|
          api.environments.named(environment_name, account_name)
        end

        case environments.size
        when 0 then raise no_environments_error
        when 1 then environments.first
        else        raise too_many_environments_error(account_and_environment_names, environments)
        end
      end

      def app_environment
        case candidates.size
        when 0 then raise no_app_environments_error
        when 1 then candidates.first
        else        raise too_many_app_environments_error
        end
      end

      private

      def no_environments_error
        if constraints[:environment_name]
          EY::APIClient::NoEnvironmentError.new(constraints[:environment_name], EY::APIClient.endpoint)
        else
          EY::APIClient::NoAppError.new(repo, EY::APIClient.endpoint)
        end
      end

      def too_many_environments_error(account_and_environment_names, environments)
        if constraints[:environment_name]
          message = "Multiple environments possible, please be more specific:\n\n"
          account_and_environment_names.each do |account_name, environment_name|
            message << "\t#{environment_name.ljust(25)} # ey <command> --environment='#{environment_name}' --account='#{account_name}'\n"
          end
          EY::APIClient::MultipleMatchesError.new(message)
        else
          EY::APIClient::AmbiguousEnvironmentGitUriError.new(environments)
        end
      end

      def no_app_environments_error
        if account_candidates.empty? && constraints[:account_name]
          EY::APIClient::NoMatchesError.new("There were no accounts that matched #{constraints[:account_name]}")
        elsif app_candidates.empty?
          if constraints[:app_name]
            EY::APIClient::InvalidAppError.new(constraints[:app_name])
          else
            EY::APIClient::NoAppError.new(repo, EY::APIClient.endpoint)
          end
        elsif environment_candidates.empty?
          EY::APIClient::NoEnvironmentError.new(constraints[:environment_name], EY::APIClient.endpoint)
        else
          message = "The matched apps & environments do not correspond with each other.\n"
          message << "Applications:\n"
          app_candidates.map{|app_env| [app_env.account_name, app_env.app_name]}.uniq.each do |account_name, app_name|
            app = api.apps.named(app_name, account_name)
            message << "\t#{app.name}\n"
            app.environments.each do |env|
              message << "\t\t#{env.name} # ey <command> -e #{env.name} -a #{app.name}\n"
            end
          end
          EY::APIClient::NoMatchesError.new(message)
        end
      end

      def too_many_app_environments_error
        message = "Multiple app deployments possible, please be more specific:\n\n"
        candidates.map do |app_env|
          [app_env.account_name, app_env.app_name]
        end.uniq.each do |account_name, app_name|
          message << "#{app_name}\n"

          candidates.select do |app_env|
            app_env.app_name == app_name && app_env.account_name == account_name
          end.map do |app_env|
            app_env.environment_name
          end.uniq.each do |env_name|
            message << "\t#{env_name.ljust(25)} # ey <command> --environment='#{env_name}' --app='#{app_name}' --account='#{account_name}'\n"
          end
        end
        EY::APIClient::MultipleMatchesError.new(message)
      end

      def repo
        constraints[:repo]
      end

      def candidates
        @candidates ||= app_candidates & environment_candidates & account_candidates
      end

      def app_candidates
        @app_candidates ||= filter_if_constrained(:app_name) || filter_by_repo || all
      end

      def environment_candidates
        @environment_candidates ||= filter_if_constrained(:environment_name) || all
      end

      def account_candidates
        @account_candidates ||= filter_if_constrained(:account_name) || all
      end

      def all
        @all ||= api.app_environments
      end

      # find by repository uri
      # if none match, return nil
      def filter_by_repo
        filter {|app_env| repo && repo.has_remote?(app_env.repository_uri) }
      end

      # If the constraint is set, the only return matches
      # if it is not set, then return all matches
      # returns exact matches, then partial matches, then all
      def filter_if_constrained(key)
        return unless constraints[key]

        match = constraints[key].downcase

        exact_match   = lambda {|app_env| app_env.send(key) == match }
        partial_match = lambda {|app_env| app_env.send(key).index(match) }

        filter(&exact_match) || filter(&partial_match) || []
      end

      # returns nil if no matches
      # returns an array of matches if any match
      def filter(&block)
        matches = all.select(&block)
        matches.empty? ? nil : matches
      end
    end
  end
end
