module Lita
  # The main object representing a running instance of Lita. Provides a high
  # level API for the underlying adapter. Dispatches incoming messages to
  # registered handlers. Can send outgoing chat messages and set the topic
  # of chat rooms.
  class Robot
    extend Forwardable

    # A +Rack+ application used for the built-in web server.
    # @return [Rack::Builder] The +Rack+ app.
    attr_reader :app

    # The {Authorization} object for the currently running robot.
    # @return [Lita::Authorization] The authorization object.
    # @since 4.0.0
    attr_reader :auth

    # The name the robot will look for in incoming messages to determine if it's
    # being addressed.
    # @return [String] The mention name.
    attr_accessor :mention_name

    # An alias the robot will look for in incoming messages to determine if it's
    # being addressed.
    # @return [String, Nil] The alias, if one was set.
    attr_accessor :alias

    # The name of the robot as it will appear in the chat.
    # @return [String] The robot's name.
    attr_accessor :name

    # The {Registry} for the currently running robot.
    # @return [Lita::Registry] The registry.
    # @since 4.0.0
    attr_reader :registry

    def_delegators :registry, :config, :adapters, :handlers, :hooks

    # @!method mention_format(name)
    #   @see Lita::Adapter#mention_format
    #   @since 4.4.0
    # @!method roster(room)
    #   @see Lita::Adapter#roster
    #   @since 4.4.1
    def_delegators :adapter, :mention_format, :roster

    # @param registry [Lita::Registry] The registry for the robot's configuration and plugins.
    def initialize(registry = Lita)
      @registry = registry
      @name = config.robot.name
      @mention_name = config.robot.mention_name || @name
      @alias = config.robot.alias
      @app = RackApp.build(self)
      @auth = Authorization.new(config)
      trigger(:loaded, room_ids: persisted_rooms)
    end

    # The primary entry point from the adapter for an incoming message.
    # Dispatches the message to all registered handlers.
    # @param message [Lita::Message] The incoming message.
    # @return [void]
    def receive(message)
      matched = handlers.map do |handler|
        next unless handler.respond_to?(:dispatch)

        handler.dispatch(self, message)
      end.any?

      trigger(:unhandled_message, message: message) unless matched
    end

    # Starts the robot, booting the web server and delegating to the adapter to
    # connect to the chat service.
    # @return [void]
    def run
      run_app
      adapter.run
    rescue Interrupt
      shut_down
    end

    # Makes the robot join a room with the specified ID.
    # @param room [Room, String] The room to join, as a {Lita::Room} object or a string identifier.
    # @return [void]
    # @since 3.0.0
    def join(room)
      room_object = find_room(room)

      if room_object
        Lita.redis.sadd("persisted_rooms", room_object.id)
        adapter.join(room_object.id)
      else
        adapter.join(room)
      end
    end

    # Makes the robot part from the room with the specified ID.
    # @param room [Room, String] The room to leave, as a {Lita::Room} object or a string identifier.
    # @return [void]
    # @since 3.0.0
    def part(room)
      room_object = find_room(room)

      if room_object
        Lita.redis.srem("persisted_rooms", room_object.id)
        adapter.part(room_object.id)
      else
        adapter.part(room)
      end
    end

    # A list of room IDs the robot should join on boot.
    # @return [Array<String>] An array of room IDs.
    # @since 4.4.2
    def persisted_rooms
      Lita.redis.smembers("persisted_rooms").sort
    end

    # Sends one or more messages to a user or room.
    # @param target [Lita::Source] The user or room to send to. If the Source
    #   has a room, it will choose the room. Otherwise, it will send to the
    #   user.
    # @param messages [Object, Array<Object>] One or more messages to send. If
    #   the message has any "to_<adapter>" method (eg.: to_shell), the result of
    #   this method will be sent to adapter, otherwise "to_s" will be called.
    # @return [void]
    def send_messages(target, *messages)
      message_method = "to_#{config.robot.adapter}".to_sym

      messages = messages.flatten.map do |message|
        if message.respond_to?(message_method)
          message.send(message_method, adapter)
        else
          message.to_s
        end
      end

      adapter.send_messages(target, messages)
    end
    alias_method :send_message, :send_messages

    # Sends one or more messages to a user or room. If sending to a room,
    # prefixes each message with the user's mention name.
    # @param target [Lita::Source] The user or room to send to. If the Source
    #   has a room, it will choose the room. Otherwise, it will send to the
    #   user.
    # @param messages [Object, Array<Object>] One or more messages to send. If
    #   the message has the "mention=" method, it'll be called with the mention
    #   string, otherwise the mention will be prepended to the message.
    # @return [void]
    # @since 3.1.0
    def send_messages_with_mention(target, *messages)
      return send_messages(target, *messages) if target.private_message?

      mention_name = target.user.mention_name
      mention = adapter.mention_format(mention_name).strip

      messages = messages.map do |message|
        if message.respond_to?(:mention=)
          message.mention = mention
          message
        else
          "#{mention} #{message}"
        end
      end

      send_messages(target, *messages)
    end
    alias_method :send_message_with_mention, :send_messages_with_mention

    # Sets the topic for a chat room.
    # @param target [Lita::Source] A source object specifying the room.
    # @param topic [String] The new topic message to set.
    # @return [void]
    def set_topic(target, topic)
      adapter.set_topic(target, topic)
    end

    # Gracefully shuts the robot down, stopping the web server and delegating
    # to the adapter to perform any shut down tasks necessary for the chat
    # service.
    # @return [void]
    def shut_down
      trigger(:shut_down_started)
      @server.stop(true) if @server
      @server_thread.join if @server_thread
      adapter.shut_down
      trigger(:shut_down_complete)
    end

    # Triggers an event, instructing all registered handlers to invoke any
    # methods subscribed to the event, and passing them a payload hash of
    # arbitrary data.
    # @param event_name [String, Symbol] The name of the event to trigger.
    # @param payload [Hash] An optional hash of arbitrary data.
    # @return [void]
    def trigger(event_name, payload = {})
      handlers.each do |handler|
        next unless handler.respond_to?(:trigger)

        handler.trigger(self, event_name, payload)
      end
    end

    private

    # Loads and caches the adapter on first access.
    def adapter
      @adapter ||= load_adapter
    end

    # Ensure the argument is a Lita::Room.
    def find_room(room_or_identifier)
      case room_or_identifier
      when Room
        room_or_identifier
      else
        Room.fuzzy_find(room_or_identifier)
      end
    end

    # Loads the selected adapter.
    def load_adapter
      adapter_name = config.robot.adapter
      adapter_class = adapters[adapter_name.to_sym]

      unless adapter_class
        Lita.logger.fatal I18n.t("lita.robot.unknown_adapter", adapter: adapter_name)
        abort
      end

      adapter_class.new(self)
    end

    # Starts the web server.
    def run_app
      http_config = config.http

      @server_thread = Thread.new do
        @server = Puma::Server.new(app)
        begin
          @server.add_tcp_listener(http_config.host, http_config.port.to_i)
        rescue Errno::EADDRINUSE, Errno::EACCES => e
          Lita.logger.fatal I18n.t(
            "lita.http.exception",
            message: e.message,
            backtrace: e.backtrace.join("\n")
          )
          abort
        end
        @server.min_threads = http_config.min_threads
        @server.max_threads = http_config.max_threads
        @server.run
      end

      @server_thread.abort_on_exception = true
    end
  end
end
