module Lita
  module Handlers
    # Provides a chat interface for administering authorization groups.
    class Authorization < Handler
      route(
        /^auth\s+add/,
        :add,
        command: true,
        restrict_to: :admins,
        help: {
        "auth add USER GROUP" => <<-HELP.chomp
Add USER to authorization group GROUP. Requires admin privileges.
HELP
        }
      )
      route(
        /^auth\s+remove/,
        :remove,
        command: true,
        restrict_to: :admins,
        help: {
        "auth remove USER GROUP" => <<-HELP.chomp
Remove USER from authorization group GROUP. Requires admin privileges.
HELP
        }
      )
      route(/^auth\s+list/, :list, command: true, restrict_to: :admins, help: {
        "auth list [GROUP]" => <<-HELP.chomp
List authorization groups and the users in them. If GROUP is supplied, only lists that group.
HELP
      })

      # Adds a user to an authorization group.
      # @param response [Lita::Response] The response object.
      # @return [void]
      def add(response)
        return unless valid_message?(response)

        if Lita::Authorization.add_user_to_group(response.user, @user, @group)
          response.reply "#{@user.name} was added to #{@group}."
        else
          response.reply "#{@user.name} was already in #{@group}."
        end
      end

      # Removes a user from an authorization group.
      # @param response [Lita::Response] The response object.
      # @return [void]
      def remove(response)
        return unless valid_message?(response)

        if Lita::Authorization.remove_user_from_group(
          response.user,
          @user,
          @group
        )
          response.reply "#{@user.name} was removed from #{@group}."
        else
          response.reply "#{@user.name} was not in #{@group}."
        end
      end

      # Lists all authorization groups (or only the specified group) and the
      # names of their members.
      # @param response [Lita::Response] The response object.
      # @return [void]
      def list(response)
        requested_group = response.args[1]
        output = get_groups_list(response.args[1])
        if output.empty?
          response.reply(empty_state_for_list(requested_group))
        else
          response.reply(output.join("\n"))
        end
      end

      private

      def empty_state_for_list(requested_group)
        if requested_group
          "There is no authorization group named #{requested_group}."
        else
          "There are no authorization groups yet."
        end
      end

      def get_groups_list(requested_group)
        groups_with_users = Lita::Authorization.groups_with_users
        if requested_group
          requested_group = requested_group.downcase.strip.to_sym
          groups_with_users.select! { |group, _| group == requested_group }
        end
        groups_with_users.map do |group, users|
          user_names = users.map { |u| u.name }.join(", ")
          "#{group}: #{user_names}"
        end
      end

      def valid_group?(response, identifier)
        unless identifier && @group
          response.reply "Format: #{robot.name} auth add USER GROUP" and return
        end

        if @group.downcase.strip == "admins"
          response.reply "Administrators can only be managed via Lita config." and return
        end

        true
      end

      # Validates that incoming messages have the right format and a valid user.
      # Also assigns the user and group to instance variables for the main
      # methods to use later.
      def valid_message?(response)
        _command, identifier, @group = response.args

        return unless valid_group?(response, identifier)

        return unless valid_user?(response, identifier)

        true
      end

      def valid_user?(response, identifier)
        @user = User.find_by_id(identifier)
        @user = User.find_by_name(identifier) unless @user

        if @user
          true
        else
          response.reply %{No user was found with the identifier "#{identifier}".} and return
        end
      end
    end

    Lita.register_handler(Authorization)
  end
end