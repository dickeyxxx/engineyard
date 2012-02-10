require 'engineyard-cloud-client/errors'
require 'engineyard-cloud-client/models'

module EY
  class CloudClient
    class App < ApiStruct.new(:id, :name, :repository_uri, :app_type_id)

      attr_reader :app_environments, :account

      def initialize(api, attrs)
        super

        @account = Account.from_hash(api, attrs['account']) if attrs['account']
        if attrs['environments']
          app_env_hashes = attrs['environments'].map { |env| {'app' => self, 'environment' => env} }
          @app_environments = AppEnvironment.from_array(api, app_env_hashes)
        end
      end

      # Return list of all Apps linked to all current user's accounts
      def self.all(api)
        self.from_array(api, api.request('/apps')["apps"])
      end

      # An everything-you-need helper to create an App
      # If successful, returns new App
      # If unsuccessful, raises +EY::CloudClient::RequestFailed+
      #
      # Usage
      # App.create(api,
      #   account:        account         # requires: account.id
      #   name:           "myapp",
      #   repository_uri: "git@github.com:mycompany/myapp.git",
      #   app_type_id:    "rails3",
      # )
      #
      # NOTE: Syntax above is for Ruby 1.9. In Ruby 1.8, keys must all be strings.
      def self.create(api, attrs = {})
        account = attrs.delete("account")
        params = attrs.dup # no default fields
        raise EY::CloudClient::AttributeRequiredError.new("account", EY::CloudClient::Account) unless account
        raise EY::CloudClient::AttributeRequiredError.new("name") unless params["name"]
        raise EY::CloudClient::AttributeRequiredError.new("repository_uri") unless params["repository_uri"]
        raise EY::CloudClient::AttributeRequiredError.new("app_type_id") unless params["app_type_id"]
        response = api.request("/accounts/#{account.id}/apps", :method => :post, :params => {"app" => params})
        self.from_hash(api, response['app'])
      end

      def account_name
        account && account.name
      end

      def environments
        (app_environments || []).map { |app_env| app_env.environment }
      end

    end
  end
end
