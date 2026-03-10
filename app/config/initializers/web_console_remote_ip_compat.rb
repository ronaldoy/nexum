if Rails.env.development?
  begin
    require "web_console/permissions"
  rescue LoadError
    # web-console may be unavailable outside development bundle contexts.
  end

  if defined?(WebConsole::Permissions) && !WebConsole::Permissions.method_defined?(:each)
    WebConsole::Permissions.include(Enumerable)

    WebConsole::Permissions.class_eval do
      def each
        return enum_for(:each) unless block_given?

        @networks.each do |network|
          yield network
        end
      end
    end
  end
end
