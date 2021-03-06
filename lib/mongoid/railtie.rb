# encoding: utf-8
require "mongoid"
require "mongoid/config"
require "mongoid/railties/document"
require "rails"
require "rails/mongoid"

module Rails
  module Mongoid

    # Hooks Mongoid into Rails 3 and higher.
    #
    # @since 2.0.0
    class Railtie < Rails::Railtie

      # Determine which generator to use. app_generators was introduced after
      # 3.0.0.
      #
      # @example Get the generators method.
      #   railtie.generators
      #
      # @return [ Symbol ] The method name to use.
      #
      # @since 2.0.0.rc.4
      def self.generator
        config.respond_to?(:app_generators) ? :app_generators : :generators
      end

      # Mapping of rescued exceptions to HTTP responses
      #
      # @example
      #   railtie.rescue_responses
      #
      # @ return [Hash] rescued responses
      #
      # @since 2.4.3
      def self.rescue_responses
        {
          "Mongoid::Errors::DocumentNotFound" => :not_found,
          "Mongoid::Errors::Validations" => 422
        }
      end

      config.send(generator).orm :mongoid, migration: false

      if config.action_dispatch.rescue_responses
        config.action_dispatch.rescue_responses.merge!(rescue_responses)
      end

      rake_tasks do
        load "mongoid/railties/database.rake"
      end

      # Exposes Mongoid's configuration to the Rails application configuration.
      #
      # @example Set up configuration in the Rails app.
      #   module MyApplication
      #     class Application < Rails::Application
      #       config.mongoid.logger = Logger.new($stdout, :warn)
      #       config.mongoid.persist_in_safe_mode = true
      #     end
      #   end
      #
      # @since 2.0.0
      config.mongoid = ::Mongoid::Config

      # Initialize Mongoid. This will look for a mongoid.yml in the config
      # directory and configure mongoid appropriately.
      #
      # @since 2.0.0
      initializer "mongoid.load-config" do
        config_file = Rails.root.join("config", "mongoid.yml")
        if config_file.file?
          begin
            ::Mongoid.load!(config_file)
          rescue ::Mongoid::Errors::NoSessionsConfig => e
            handle_configuration_error(e)
          rescue ::Mongoid::Errors::NoDefaultSession => e
            handle_configuration_error(e)
          rescue ::Mongoid::Errors::NoSessionDatabase => e
            handle_configuration_error(e)
          rescue ::Mongoid::Errors::NoSessionHosts => e
            handle_configuration_error(e)
          end
        end
      end

      # Set the proper error types for Rails. DocumentNotFound errors should be
      # 404s and not 500s, validation errors are 422s.
      #
      # @since 2.0.0
      config.after_initialize do
        unless config.action_dispatch.rescue_responses
          ActionDispatch::ShowExceptions.rescue_responses.update(Railtie.rescue_responses)
        end
      end

      # Due to all models not getting loaded and messing up inheritance queries
      # and indexing, we need to preload the models in order to address this.
      #
      # This will happen every request in development, once in ther other
      # environments.
      #
      # @since 2.0.0
      initializer "mongoid.preload-models" do |app|
        config.to_prepare do
          ::Rails::Mongoid.preload_models(app)
        end
      end

      # Need to include the Mongoid identity map middleware.
      #
      # @since 3.0.0
      initializer "mongoid.use-identity-map-middleware" do |app|
        app.config.middleware.use "Rack::Mongoid::Middleware::IdentityMap"
      end

      config.after_initialize do
        # Unicorn clears the START_CTX when a worker is forked, so if we have
        # data in START_CTX then we know we're being preloaded. Unicorn does
        # not provide application-level hooks for executing code after the
        # process has forked, so we reconnect lazily.
        if defined?(Unicorn) && !Unicorn::HttpServer::START_CTX.empty?
          ::Mongoid.default_session.disconnect if ::Mongoid.configured?
        end

        # Passenger provides the :starting_worker_process event for executing
        # code after it has forked, so we use that and reconnect immediately.
        if ::Mongoid.running_with_passenger?
          PhusionPassenger.on_event(:starting_worker_process) do |forked|
            ::Mongoid.default_session.disconnect if forked
          end
        end
      end

      # Rails runs all initializers first before getting into any generator
      # code, so we have no way in the intitializer to know if we are
      # generating a mongoid.yml. So instead of failing, we catch all the
      # errors and print them out.
      #
      # @since 3.0.0
      def handle_configuration_error(e)
        puts "There is a configuration error with the current mongoid.yml."
        puts e.message
      end

      # Clears the idenity map on console reload. Identity map is on a thread
      # local so it's safe to clear it in all environments.
      #
      # @since 4.0.0
      ActionDispatch::Reloader.to_cleanup do
        ::Mongoid::IdentityMap.clear
      end
    end
  end
end
