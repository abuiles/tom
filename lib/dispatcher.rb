require "em-synchrony/fiber_iterator"
require 'logger'

module Tom

  LOG = ::Logger.new(STDOUT)
  LOG.level = ::Logger::ERROR
  LOG.datetime_format = "%H:%M:%S:"
  Logger::Formatter.module_eval(
    %q{ def call(severity, time, progname, msg)} +
    %q{ "#{format_datetime(time)} #{msg2str(msg)}\n" end}
  )

  class Dispatcher

    #
    #  Dispatches this request to all adapters that registered
    #  for the route and then calls the merger for this route
    #  to compose a response
    #
    def self.dispatch(env)
      adapters = adapters_for_route(env)
      return [404, {}, '{reason: "No adapters for this route"}'] if adapters.empty?

      # Hit APIs. All at the same time. Oh, mygodd!
      responses = {}
      Tom::LOG.info "#{env['REQUEST_METHOD'].upcase} #{env['REQUEST_URI']}"
      Tom::LOG.info "Dispatching to:"
      EM::Synchrony::FiberIterator.new(adapters, adapters.count).map do |clazz|
        Tom::LOG.info "  -> #{clazz}"
        (responses[clazz] ||= []) <<  clazz.new.handle(env)
      end

      merged = merge(env, responses)
      Tom::LOG.info "-------------------------------------------------------n"
      merged
    end

    #
    #  Takes a request (rack env) and a couple of responses
    #  generated by api adapters and composes a response for the
    #  client.
    #
    #  The merger used depends on the route.
    #
    def self.merge(env, responses)
      merger = merger_for_route(env)
      Tom::LOG.info "Merging with:"
      Tom::LOG.info "  -> #{merger}"
      merger.new.merge env, responses
    end

    #
    #  Registers a opts[:adapter] or opts[:merger] for the 
    #  given opts[:route].
    #
    #  This method should not be called directly, use register_route
    #  in Tom::Adapter or Tom::Merger instead.
    #
    def self.register(opts)
      return register_adapter(opts) if opts[:adapter]
      return register_merger(opts)  if opts[:merger]
      raise "You need to supply opts[:adapter] or opts[:merger]"
    end

    private

    #
    #  Registers an adapter for a given route and request method
    #
    def self.register_adapter(opts)
      validate_type(opts[:adapter], Adapter)
      methods = get_methods(opts)
      @adapters ||= default_methods_hash
      methods.each do |method|
        @adapters[method][opts[:route]] ||= []
        @adapters[method][opts[:route]] << opts[:adapter]
      end
    end

    #
    #  Registers merger for a given route and request method
    #
    def self.register_merger(opts)
      validate_type(opts[:merger], Merger)
      methods = get_methods(opts)
      @mergers ||= default_methods_hash
      methods.each do |method|
        @mergers[method][opts[:route]] ||= []
        @mergers[method][opts[:route]] << opts[:merger]
      end
    end

    #
    #  Fetches the methods from the options hash, defaults
    #  to all methods.
    #
    def self.get_methods(opts)
      return opts[:methods] unless opts[:methods].empty?
      [:head, :get, :put, :post, :delete]
    end

    #
    #  Just some defaults to initialize thing
    #
    def self.default_methods_hash
      { head:   {},
        get:    {},
        put:    {},
        post:   {},
        delete: {}
      }
    end

    #
    #  Find the right adapter for a route
    #
    def self.adapters_for_route(env)
      @adapters ||= default_methods_hash
      route, method = route_and_method(env)
      matches = []
      @adapters[method].map do |reg_route, adapters|
        next unless reg_route.match(route)
        matches += adapters
      end
      matches.uniq
    end

    #
    #  Find the right merger for a route
    #
    def self.merger_for_route(env)
      @mergers ||= default_methods_hash
      route, method = route_and_method(env)
      @mergers[method].each do |reg_route, mergers|
        next unless reg_route.match(route)
        return mergers.first
      end
      raise "Found no merger for route #{route}"
    end

    #
    #  Extract the route/request uri and the method from a
    #  rack env
    #
    def self.route_and_method(env)
      [env["REQUEST_PATH"],
       env["REQUEST_METHOD"].downcase.to_sym]
    end

    #
    #  Make sure one class is a subclass of another class
    #
    def self.validate_type(c, expected)
      return if c < expected
      raise "Invalid type. Expected #{expected} got #{c}"
    end

  end
end
