module Vanity

  # Playground catalogs all your experiments, holds the Vanity configuration.
  #
  # @example
  #   Vanity.playground.logger = my_logger
  #   puts Vanity.playground.map(&:name)
  class Playground

    DEFAULTS = { :host=>"127.0.0.1", :port=>6379, :db=>0, :load_path=>"experiments" }

    # Created new Playground. Unless you need to, use the global Vanity.playground.
    def initialize(options = {})
      options = DEFAULTS.merge(options)
      adapter = options[:adapter] || options[:redis] || :redis
      if adapter.respond_to?(:mget)
        @redis = adapter
      elsif adapter == :redis
        @host, @port, @db = options.values_at(:host, :port, :db)
      else
        require "vanity/store/#{adapter}"
        @redis = Vanity::Store.const_get(adapter.to_s.classify).new
      end
      @load_path = options[:load_path]
      @namespace = "vanity:#{Vanity::Version::MAJOR}"
      @logger = options[:logger]
      unless @logger
        @logger = Logger.new(STDOUT)
        @logger.level = Logger::ERROR
      end
      @loading = []
    end
    
    # Redis host name.  Default is 127.0.0.1
    attr_accessor :host

    # Redis port number.  Default is 6379.
    attr_accessor :port

    # Redis database number. Default is 0.
    attr_accessor :db

    # Redis database password.
    attr_accessor :password

    # Namespace for database keys.  Default is vanity:n, where n is the major release number, e.g. vanity:1 for 1.0.3.
    attr_accessor :namespace

    # Path to load experiment files from.
    attr_accessor :load_path

    # Logger.
    attr_accessor :logger

    # Defines a new experiment. Generally, do not call this directly,
    # use one of the definition methods (ab_test, measure, etc).
    #
    # @see Vanity::Experiment
    def define(name, type, options = {}, &block)
      warn "Deprecated: if you need this functionality let's make a better API"
      id = name.to_s.downcase.gsub(/\W/, "_").to_sym
      raise "Experiment #{id} already defined once" if experiments[id]
      klass = Experiment.const_get(type.to_s.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase })
      experiment = klass.new(self, id, name, options)
      experiment.instance_eval &block
      experiment.save
      experiments[id] = experiment
    end

    # Returns the experiment. You may not have guessed, but this method raises
    # an exception if it cannot load the experiment's definition.
    #
    # @see Vanity::Experiment
    def experiment(name)
      id = name.to_s.downcase.gsub(/\W/, "_").to_sym
      warn "Deprecated: pleae call experiment method with experiment identifier (a Ruby symbol)" unless id == name
      experiments[id.to_sym] or raise NameError, "No experiment #{id}"
    end

    # Returns hash of experiments (key is experiment id).
    #
    # @see Vanity::Experiment
    def experiments
      unless @experiments
        @experiments = {}
        @logger.info "Vanity: loading experiments from #{load_path}"
        Dir[File.join(load_path, "*.rb")].each do |file|
          Experiment::Base.load self, @loading, file
        end
      end
      @experiments
    end

    # Reloads all metrics and experiments.  Rails calls this for each request in
    # development mode.
    def reload!
      @experiments = nil
      @metrics = nil
      load!
    end

    # Loads all metrics and experiments.  Rails calls this during
    # initialization.
    def load!
      experiments
      metrics
    end

    # Use this instance to access the Redis database.
    def redis
      @redis ||= Redis.new(:host=>self.host, :port=>self.port, :db=>self.db,
                           :password=>self.password, :logger=>self.logger)
      class << self ; self ; end.send(:define_method, :redis) { @redis }
      @redis
    end

    # Switches playground to use Vanity::Store::Mock instead of a live server.
    # Particularly useful for testing, e.g. if you can't access Redis on your CI
    # server.  This method has no affect after playground accesses live Redis
    # server.
    #
    # @example Put this in config/environments/test.rb
    #   config.after_initialize { Vanity.playground.mock! }
    def mock!
      @redis ||= Vanity::Store::Mock.new
    end

    # Returns a metric (raises NameError if no metric with that identifier).
    #
    # @see Vanity::Metric
    # @since 1.1.0
    def metric(id)
      metrics[id.to_sym] or raise NameError, "No metric #{id}"
    end

    # Returns hash of metrics (key is metric id).
    #
    # @see Vanity::Metric
    # @since 1.1.0
    def metrics
      unless @metrics
        @metrics = {}
        @logger.info "Vanity: loading metrics from #{load_path}/metrics"
        Dir[File.join(load_path, "metrics/*.rb")].each do |file|
          Metric.load self, @loading, file
        end
      end
      @metrics
    end

    # Tracks an action associated with a metric.
    #
    # @example
    #   Vanity.playground.track! :uploaded_video
    #
    # @since 1.1.0
    def track!(id, count = 1)
      metric(id).track! count
    end
  end

  @playground = Playground.new
  class << self

    # The playground instance.
    #
    # @see Vanity::Playground
    attr_accessor :playground

    # Returns the Vanity context.  For example, when using Rails this would be
    # the current controller, which can be used to get/set the vanity identity.
    def context
      Thread.current[:vanity_context]
    end

    # Sets the Vanity context.  For example, when using Rails this would be
    # set by the set_vanity_context before filter (via Vanity::Rails#use_vanity).
    def context=(context)
      Thread.current[:vanity_context] = context
    end

    # Path to template.
    def template(name)
      path = File.join(File.dirname(__FILE__), "templates/#{name}")
      path << ".erb" unless name["."]
      path
    end

  end
end


class Object

  # Use this method to access an experiment by name.
  #
  # @example
  #   puts experiment(:text_size).alternatives
  #
  # @see Vanity::Playground#experiment
  # @deprecated
  def experiment(name)
    warn "Deprecated. Please call Vanity.playground.experiment directly."
    Vanity.playground.experiment(name)
  end
end
