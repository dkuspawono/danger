# Following the advice from @czechboy0 https://github.com/danger/danger/issues/171

module Danger
  module CISource
    class XcodeServer < CI
      def self.validates?(env)
        return false unless env['XCS_BOT_NAME']

        return true
      end

      def supported_request_sources
        @supported_request_sources ||= [Danger::RequestSources::GitHub]
      end

      def initialize(env)
        bot_name = env['XCS_BOT_NAME']
        return if bot_name.nil?

        repo_matches = bot_name.match(/\[(.+)\]/)
        self.repo_slug = repo_matches[1] unless repo_matches.nil?
        pull_request_id_matches = bot_name.match(/#(\d+)/)
        self.pull_request_id = pull_request_id_matches[1] unless pull_request_id_matches.nil?
        self.repo_url = GitRepo.new.origins # Xcode Server doesn't provide a repo url env variable :/
      end
    end
  end
end
