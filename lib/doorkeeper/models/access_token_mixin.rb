module Doorkeeper
  module AccessTokenMixin
    extend ActiveSupport::Concern

    include OAuth::Helpers
    include Models::Expirable
    include Models::Revocable
    include Models::Accessible
    include Models::Scopes
    include ActiveModel::MassAssignmentSecurity if defined?(::ProtectedAttributes)

    included do
      belongs_to_options = {
        class_name: 'Doorkeeper::Application',
        inverse_of: :access_tokens
      }
      if defined?(ActiveRecord::Base) && ActiveRecord::VERSION::MAJOR >= 5
        belongs_to_options[:optional] = true
      end

      belongs_to :application, belongs_to_options

      validates :token, presence: true, uniqueness: true
      validates :refresh_token, uniqueness: true, if: :use_refresh_token?

      attr_writer :use_refresh_token

      before_validation :generate_token, on: :create
      before_validation :generate_refresh_token,
                        on: :create,
                        if: :use_refresh_token?
    end

    module ClassMethods
      def by_token(token)
        find_by(token: token.to_s)
      end

      def by_refresh_token(refresh_token)
        find_by(refresh_token: refresh_token.to_s)
      end

      def revoke_all_for(application_id, resource_owner)
        where(application_id: application_id,
              resource_owner_id: resource_owner.id,
              revoked_at: nil).
          each(&:revoke)
      end

      def matching_token_for(application, resource_owner_or_id, scopes)
        resource_owner_id = if resource_owner_or_id.respond_to?(:to_key)
                              resource_owner_or_id.id
                            else
                              resource_owner_or_id
                            end
        token = last_authorized_token_for(application.try(:id), resource_owner_id)
        if token && scopes_match?(token.scopes, scopes, application.try(:scopes))
          token
        end
      end

      def scopes_match?(token_scopes, param_scopes, app_scopes)
        (!token_scopes.present? && !param_scopes.present?) ||
          Doorkeeper::OAuth::Helpers::ScopeChecker.match?(
            token_scopes.to_s,
            param_scopes,
            app_scopes
          )
      end

      def find_or_create_for(application, resource_owner_id, scopes, expires_in, use_refresh_token)
        if Doorkeeper.configuration.reuse_access_token
          access_token = matching_token_for(application, resource_owner_id, scopes)
          if access_token && !access_token.expired?
            return access_token
          end
        end

        create!(
          application_id:    application.try(:id),
          resource_owner_id: resource_owner_id,
          scopes:            scopes.to_s,
          expires_in:        expires_in,
          use_refresh_token: use_refresh_token
        )
      end

      def last_authorized_token_for(application_id, resource_owner_id)
        send(order_method, created_at_desc).
          find_by(application_id: application_id,
                  resource_owner_id: resource_owner_id,
                  revoked_at: nil)
      end
    end

    def token_type
      'bearer'
    end

    def use_refresh_token?
      @use_refresh_token ||= false
      !!@use_refresh_token
    end

    def as_json(_options = {})
      {
        resource_owner_id:  resource_owner_id,
        scopes:             scopes,
        expires_in_seconds: expires_in_seconds,
        application:        { uid: application.try(:uid) },
        created_at:         created_at.to_i
      }
    end

    # It indicates whether the tokens have the same credential
    def same_credential?(access_token)
      application_id == access_token.application_id &&
        resource_owner_id == access_token.resource_owner_id
    end

    def acceptable?(scopes)
      accessible? && includes_scope?(*scopes)
    end

    private

    def generate_refresh_token
      write_attribute :refresh_token, UniqueToken.generate
    end

    def generate_token
      self.created_at ||= Time.now.utc

      generator = Doorkeeper.configuration.access_token_generator.constantize
      self.token = generator.generate(
        resource_owner_id: resource_owner_id,
        scopes: scopes,
        application: application,
        expires_in: expires_in,
        created_at: created_at
      )
    rescue NoMethodError
      raise Errors::UnableToGenerateToken, "#{generator} does not respond to `.generate`."
    rescue NameError
      raise Errors::TokenGeneratorNotFound, "#{generator} not found"
    end
  end
end
