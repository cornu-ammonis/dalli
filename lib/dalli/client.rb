require 'digest/md5'
require 'set'

# encoding: ascii
module Dalli
  class Client

    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    #
    #   Dalli::Client.new(['localhost:11211:10', 'cache-2.example.com:11211:5', '192.168.0.1:22122:5'],
    #                   :threadsafe => true, :failover => true, :expires_in => 300)
    #
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Both weight and port are optional.  If you pass in nil, Dalli will use the <tt>MEMCACHE_SERVERS</tt>
    # environment variable or default to 'localhost:11211' if it is not present.
    #
    # Options:
    # - :namespace - prepend each key with this value to provide simple namespacing.
    # - :failover - if a server is down, look for and store values on another server in the ring.  Default: true.
    # - :threadsafe - ensure that only one thread is actively using a socket at a time. Default: true.
    # - :expires_in - default TTL in seconds if you do not pass TTL as a parameter to an individual operation, defaults to 0 or forever
    # - :compress - defaults to false, if true Dalli will compress values larger than 1024 bytes before sending them to memcached.
    # - :serializer - defaults to Marshal
    # - :compressor - defaults to zlib
    #
    def initialize(servers=nil, options={})
      @servers = normalize_servers(servers || ENV["MEMCACHE_SERVERS"] || '127.0.0.1:11211')
      @options = normalize_options(options)
      @ring = nil
    end

    ##
    # Normalizes the argument into an array of servers. If the argument is a string, it's expected to be of
    # the format "memcache1.example.com:11211[,memcache2.example.com:11211[,memcache3.example.com:11211[...]]]
    def normalize_servers(servers)
      if servers.is_a? String
        return servers.split(",")
      else
        return servers
      end
    end

    #
    # The standard memcached instruction set
    #

    ##
    # Turn on quiet aka noreply support.
    # All relevant operations within this block will be effectively
    # pipelined as Dalli will use 'quiet' operations where possible.
    # Currently supports the set, add, replace and delete operations.
    def multi
      old, Thread.current[:dalli_multi] = Thread.current[:dalli_multi], true
      yield
    ensure
      Thread.current[:dalli_multi] = old
    end

    def get(key, options=nil)
      resp = perform(:get, key)
      resp.nil? || 'Not found' == resp ? nil : resp
    end

    def groups_for_keys(*keys)
      groups = mapped_keys(keys).flatten.group_by do |key|
        begin
          ring.server_for_key(key)
        rescue Dalli::RingError
          Dalli.logger.debug { "unable to get key #{key}" }
          nil
        end
      end
      return groups
    end

    def mapped_keys(keys)
      keys.flatten.map {|a| validate_key(a.to_s)}
    end

    def make_multi_get_requests(groups)
      groups.each do |server, keys_for_server|
        begin
          # TODO: do this with the perform chokepoint?
          # But given the fact that fetching the response doesn't take place
          # in that slot it's misleading anyway. Need to move all of this method
          # into perform to be meaningful
          server.request(:send_multiget, keys_for_server)
        rescue DalliError, NetworkError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "unable to get keys for server #{server.hostname}:#{server.port}" }
        end
      end
    end

    def perform_multi_response_start(servers)
      servers.each do |server|
        next unless server.alive?
        begin
          server.multi_response_start
        rescue DalliError, NetworkError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "results from this server will be missing" }
          servers.delete(server)
        end
      end
      servers
    end

    ##
    # Fetch multiple keys efficiently.
    # Returns a hash of { 'key' => 'value', 'key2' => 'value1' }
    def get_multi(*keys)
      perform do
        return {} if keys.empty?
        options = nil
        options = keys.pop if keys.last.is_a?(Hash) || keys.last.nil?
        ring.lock do
          begin
            groups = groups_for_keys(keys)
            if unfound_keys = groups.delete(nil)
              Dalli.logger.debug { "unable to get keys for #{unfound_keys.length} keys because no matching server was found" }
            end
            make_multi_get_requests(groups)

            servers = groups.keys
            values = {}
            return values if servers.empty?
            servers = perform_multi_response_start(servers)

            start = Time.now
            loop do
              # remove any dead servers
              servers.delete_if { |s| s.sock.nil? }
              break if servers.empty?

              # calculate remaining timeout
              elapsed = Time.now - start
              timeout = servers.first.options[:socket_timeout]
              if elapsed > timeout
                readable = nil
              else
                sockets = servers.map(&:sock)
                readable, _ = IO.select(sockets, nil, nil, timeout - elapsed)
              end

              if readable.nil?
                # no response within timeout; abort pending connections
                servers.each do |server|
                  Dalli.logger.debug { "memcached at #{server.name} did not response within timeout" }
                  server.multi_response_abort
                end
                break

              else
                readable.each do |sock|
                  server = sock.server

                  begin
                    server.multi_response_nonblock.each do |key, value|
                      values[key_without_namespace(key)] = value
                    end

                    if server.multi_response_completed?
                      servers.delete(server)
                    end
                  rescue NetworkError
                    servers.delete(server)
                  end
                end
              end
            end

            values
          end
        end
      end
    end

    def fetch(key, ttl=nil, options=nil)
      ttl ||= @options[:expires_in].to_i
      val = get(key, options)
      if val.nil? && block_given?
        val = yield
        add(key, val, ttl, options)
      end
      val
    end

    ##
    # compare and swap values using optimistic locking.
    # Fetch the existing value for key.
    # If it exists, yield the value to the block.
    # Add the block's return value as the new value for the key.
    # Add will fail if someone else changed the value.
    #
    # Returns:
    # - nil if the key did not exist.
    # - false if the value was changed by someone else.
    # - true if the value was successfully updated.
    def cas(key, ttl=nil, options=nil, &block)
      ttl ||= @options[:expires_in].to_i
      (value, cas) = perform(:cas, key)
      value = (!value || value == 'Not found') ? nil : value
      if value
        newvalue = block.call(value)
        perform(:set, key, newvalue, ttl, cas, options)
      end
    end

    def set(key, value, ttl=nil, options=nil)
      ttl ||= @options[:expires_in].to_i
      perform(:set, key, value, ttl, 0, options)
    end

    ##
    # Conditionally add a key/value pair, if the key does not already exist
    # on the server.  Returns true if the operation succeeded.
    def add(key, value, ttl=nil, options=nil)
      ttl ||= @options[:expires_in].to_i
      perform(:add, key, value, ttl, options)
    end

    ##
    # Conditionally add a key/value pair, only if the key already exists
    # on the server.  Returns true if the operation succeeded.
    def replace(key, value, ttl=nil, options=nil)
      ttl ||= @options[:expires_in].to_i
      perform(:replace, key, value, ttl, options)
    end

    def delete(key)
      perform(:delete, key)
    end

    ##
    # Append value to the value already stored on the server for 'key'.
    # Appending only works for values stored with :raw => true.
    def append(key, value)
      perform(:append, key, value.to_s)
    end

    ##
    # Prepend value to the value already stored on the server for 'key'.
    # Prepending only works for values stored with :raw => true.
    def prepend(key, value)
      perform(:prepend, key, value.to_s)
    end

    def flush(delay=0)
      time = -delay
      ring.servers.map { |s| s.request(:flush, time += delay) }
    end

    alias_method :flush_all, :flush

    ##
    # Incr adds the given amount to the counter on the memcached server.
    # Amt must be a positive integer value.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    #
    # Note that the ttl will only apply if the counter does not already
    # exist.  To increase an existing counter and update its TTL, use
    # #cas.
    def incr(key, amt=1, ttl=nil, default=nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      ttl ||= @options[:expires_in].to_i
      perform(:incr, key, amt.to_i, ttl, default)
    end

    ##
    # Decr subtracts the given amount from the counter on the memcached server.
    # Amt must be a positive integer value.
    #
    # memcached counters are unsigned and cannot hold negative values.  Calling
    # decr on a counter which is 0 will just return 0.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    #
    # Note that the ttl will only apply if the counter does not already
    # exist.  To decrease an existing counter and update its TTL, use
    # #cas.
    def decr(key, amt=1, ttl=nil, default=nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      ttl ||= @options[:expires_in].to_i
      perform(:decr, key, amt.to_i, ttl, default)
    end

    ##
    # Touch updates expiration time for a given key.
    #
    # Returns true if key exists, otherwise nil.
    def touch(key, ttl=nil)
      ttl ||= @options[:expires_in].to_i
      resp = perform(:touch, key, ttl)
      resp.nil? ? nil : true
    end

    ##
    # Collect the stats for each server.
    # You can optionally pass a type including :items or :slabs to get specific stats
    # Returns a hash like { 'hostname:port' => { 'stat1' => 'value1', ... }, 'hostname2:port' => { ... } }
    def stats(type=nil)
      type = nil if ![nil, :items,:slabs].include? type
      values = {}
      ring.servers.each do |server|
        values["#{server.hostname}:#{server.port}"] = server.alive? ? server.request(:stats,type.to_s) : nil
      end
      values
    end

    ##
    # Reset stats for each server.
    def reset_stats
      ring.servers.map do |server|
        server.alive? ? server.request(:reset_stats) : nil
      end
    end

    ##
    ## Version of the memcache servers.
    def version
      values = {}
      ring.servers.each do |server|
        values["#{server.hostname}:#{server.port}"] = server.alive? ? server.request(:version) : nil
      end
      values
    end

    ##
    # Close our connection to each server.
    # If you perform another operation after this, the connections will be re-established.
    def close
      if @ring
        @ring.servers.each { |s| s.close }
        @ring = nil
      end
    end
    alias_method :reset, :close

    private

    def ring
      @ring ||= Dalli::Ring.new(
        @servers.map do |s|
         server_options = {}
          if s =~ %r{\Amemcached://}
            uri = URI.parse(s)
            server_options[:username] = uri.user
            server_options[:password] = uri.password
            s = "#{uri.host}:#{uri.port}"
          end
          Dalli::Server.new(s, @options.merge(server_options))
        end, @options
      )
    end

    # Chokepoint method for instrumentation
    def perform(*all_args, &blk)
      return blk.call if blk
      op, key, *args = *all_args

      key = key.to_s
      key = validate_key(key)
      begin
        server = ring.server_for_key(key)
        ret = server.request(op, key, *args)
        ret
      rescue NetworkError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "retrying request with new server" }
        retry
      end
    end

    def validate_key(key)
      raise ArgumentError, "key cannot be blank" if !key || key.length == 0
      key = key_with_namespace(key)
      if key.length > 250
        max_length_before_namespace = 212 - (namespace || '').size
        key = "#{key[0, max_length_before_namespace]}:md5:#{Digest::MD5.hexdigest(key)}"
      end
      return key
    end

    def key_with_namespace(key)
      (ns = namespace) ? "#{ns}:#{key}" : key
    end

    def key_without_namespace(key)
      (ns = namespace) ? key.sub(%r(\A#{ns}:), '') : key
    end

    def namespace
      @options[:namespace].is_a?(Proc) ? @options[:namespace].call : @options[:namespace]
    end

    def normalize_options(opts)
      if opts[:compression]
        Dalli.logger.warn "DEPRECATED: Dalli's :compression option is now just :compress => true.  Please update your configuration."
        opts[:compress] = opts.delete(:compression)
      end
      begin
        opts[:expires_in] = opts[:expires_in].to_i if opts[:expires_in]
      rescue NoMethodError
        raise ArgumentError, "cannot convert :expires_in => #{opts[:expires_in].inspect} to an integer"
      end
      opts
    end
  end
end
