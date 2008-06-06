module AWS
  module S3
    class Connection #:nodoc:
      class << self
        def connect(options = {})
          new(options)
        end
        
        def prepare_path(path)
          path = path.remove_extended unless path.utf8?
          URI.escape(path)
        end
      end
      
      attr_reader :access_key_id, :secret_access_key, :http, :options
      
      # Creates a new connection. Connections make the actual requests to S3, though these requests are usually 
      # called from subclasses of Base.
      # 
      # For details on establishing connections, check the Connection::Management::ClassMethods.
      def initialize(options = {})
        @options = Options.new(options)
        connect
      end
          
      def request(verb, path, headers = {}, body = nil, attempts = 0, &block)
        body.rewind if body.respond_to?(:rewind) unless attempts.zero?      
        
        requester = Proc.new do 
          path    = self.class.prepare_path(path)
          request = request_method(verb).new(path, headers)
          ensure_content_type!(request)
          add_user_agent!(request)
          authenticate!(request)
          if body
            if body.respond_to?(:read)                                                                
              request.body_stream    = body                                                           
              request.content_length = body.respond_to?(:lstat) ? body.lstat.size : body.size         
            else                                                                                      
              request.body = body                                                                     
            end                                                                                       
          end
          http.request(request, &block)
        end
        
        if persistent?
          http.start unless http.started?
          requester.call
        else
          http.start(&requester)
        end
      rescue Errno::EPIPE, Timeout::Error, Errno::EPIPE, Errno::EINVAL
        @http = create_connection
        attempts == 3 ? raise : (attempts += 1; retry)
      end
      
      def url_for(path, options = {})
        authenticate = options.delete(:authenticated)
        # Default to true unless explicitly false
        authenticate = true if authenticate.nil? 
        path         = self.class.prepare_path(path)
        request      = request_method(:get).new(path, {})
        query_string = query_string_authentication(request, options)
        returning "#{protocol(options)}#{http.address}#{port_string}#{path}" do |url|
          url << "?#{query_string}" if authenticate
        end
      end
      
      def subdomain
        http.address[/^([^.]+).#{DEFAULT_HOST}$/, 1]
      end
      
      def persistent?
        options[:persistent]
      end
      
      def protocol(options = {})
        (options[:use_ssl] || http.use_ssl?) ? 'https://' : 'http://'
      end
      
      private
        def extract_keys!
          missing_keys = []
          extract_key = Proc.new {|key| options[key] || (missing_keys.push(key); nil)}
          @access_key_id     = extract_key[:access_key_id]
          @secret_access_key = extract_key[:secret_access_key]
          raise MissingAccessKey.new(missing_keys) unless missing_keys.empty?
        end
        
        def create_connection
          http             = http_class.new(options[:server], options[:port])
          http.use_ssl     = !options[:use_ssl].nil? || options[:port] == 443
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http
        end
        
        def http_class
          if options.connecting_through_proxy?
            Net::HTTP::Proxy(*options.proxy_settings)
          else
            Net::HTTP
          end
        end
        
        def connect
          extract_keys!
          @http = create_connection
        end

        def port_string
          default_port = options[:use_ssl] ? 443 : 80
          http.port == default_port ? '' : ":#{http.port}"
        end

        def ensure_content_type!(request)
          request['Content-Type'] ||= 'binary/octet-stream'
        end
        
        # Just do Header authentication for now
        def authenticate!(request)
          request['Authorization'] = Authentication::Header.new(request, access_key_id, secret_access_key)
        end
        
        def add_user_agent!(request)
          request['User-Agent'] ||= "AWS::S3/#{Version}"
        end
        
        def query_string_authentication(request, options = {})
          Authentication::QueryString.new(request, access_key_id, secret_access_key, options)
        end

        def request_method(verb)
          Net::HTTP.const_get(verb.to_s.capitalize)
        end
        
        def method_missing(method, *args, &block)
          options[method] || super
        end
        
      module Management #:nodoc:
        def self.included(base)
          base.cattr_accessor :connections
          base.connections = {}
          base.extend ClassMethods
        end
        
        # Manage the creation and destruction of connections for AWS::S3::Base and its subclasses. Connections are
        # created with establish_connection!.
        module ClassMethods
          # Creates a new connection with which to make requests to the S3 servers for the calling class.
          #   
          #   AWS::S3::Base.establish_connection!(:access_key_id => '...', :secret_access_key => '...')
          #
          # You can set connections for every subclass of AWS::S3::Base. Once the initial connection is made on
          # Base, all subsequent connections will inherit whatever values you don't specify explictly. This allows you to
          # customize details of the connection, such as what server the requests are made to, by just specifying one 
          # option. 
          #
          #   AWS::S3::Bucket.established_connection!(:use_ssl => true)
          #
          # The Bucket connection would inherit the <tt>:access_key_id</tt> and the <tt>:secret_access_key</tt> from
          # Base's connection. Unlike the Base connection, all Bucket requests would be made over SSL.
          #
          # == Required arguments
          #
          # * <tt>:access_key_id</tt> - The access key id for your S3 account. Provided by Amazon.
          # * <tt>:secret_access_key</tt> - The secret access key for your S3 account. Provided by Amazon.
          #
          # If any of these required arguments is missing, a MissingAccessKey exception will be raised.
          #
          # == Optional arguments
          #
          # * <tt>:server</tt> - The server to make requests to. You can use this to specify your bucket in the subdomain,
          # or your own domain's cname if you are using virtual hosted buckets. Defaults to <tt>s3.amazonaws.com</tt>.
          # * <tt>:port</tt> - The port to the requests should be made on. Defaults to 80 or 443 if the <tt>:use_ssl</tt>
          # argument is set.
          # * <tt>:use_ssl</tt> - Whether requests should be made over SSL. If set to true, the <tt>:port</tt> argument
          # will be implicitly set to 443, unless specified otherwise. Defaults to false.
          # * <tt>:persistent</tt> - Whether to use a persistent connection to the server. Having this on provides around a two fold 
          # performance increase but for long running processes some firewalls may find the long lived connection suspicious and close the connection.
          # If you run into connection errors, try setting <tt>:persistent</tt> to false. Defaults to true.
          # * <tt>:proxy</tt> - If you need to connect through a proxy, you can specify your proxy settings by specifying a <tt>:host</tt>, <tt>:port</tt>, <tt>:user</tt>, and <tt>:password</tt>
          # with the <tt>:proxy</tt> option.
          # The <tt>:host</tt> setting is required if specifying a <tt>:proxy</tt>. 
          #   
          #   AWS::S3::Bucket.established_connection!(:proxy => {
          #     :host => '...', :port => 8080, :user => 'marcel', :password => 'secret'
          #   })
          def establish_connection!(options = {})
            # After you've already established the default connection, just specify 
            # the difference for subsequent connections
            options = default_connection.options.merge(options) if connected?
            connections[connection_name] = Connection.connect(options)
          end
          
          # Returns the connection for the current class, or Base's default connection if the current class does not
          # have its own connection.
          #
          # If not connection has been established yet, NoConnectionEstablished will be raised.
          def connection
            if connected?
              connections[connection_name] || default_connection
            else
              raise NoConnectionEstablished
            end
          end
          
          # Returns true if a connection has been made yet.
          def connected?
            !connections.empty?
          end
          
          # Removes the connection for the current class. If there is no connection for the current class, the default
          # connection will be removed.
          def disconnect(name = connection_name)
            name       = default_connection unless connections.has_key?(name)
            connection = connections[name]
            connection.http.finish if connection.persistent?
            connections.delete(name)
          end
          
          # Clears *all* connections, from all classes, with prejudice. 
          def disconnect!
            connections.each_key {|connection| disconnect(connection)}
          end

          private
            def connection_name
              name
            end

            def default_connection_name
              'AWS::S3::Base'
            end

            def default_connection
              connections[default_connection_name]
            end
        end
      end
        
      class Options < Hash #:nodoc:
        class << self
          def valid_options
            [:access_key_id, :secret_access_key, :server, :port, :use_ssl, :persistent, :proxy]
          end
        end
        
        attr_reader :options
        def initialize(options = {})
          super()
          @options = options
          validate!
          extract_proxy_settings!
          extract_persistent!
          extract_server!
          extract_port!
          extract_remainder!
        end
        
        def connecting_through_proxy?
          !self[:proxy].nil?
        end
        
        def proxy_settings
          proxy_setting_keys.map do |proxy_key| 
            self[:proxy][proxy_key]
          end
        end
        
        private
          def proxy_setting_keys
            [:host, :port, :user, :password]
          end
          
          def missing_proxy_settings?
            !self[:proxy].keys.include?(:host)
          end
          
          def extract_persistent!
            self[:persistent] = options.has_key?(:persitent) ? options[:persitent] : true
          end
          
          def extract_proxy_settings!
            self[:proxy] = options.delete(:proxy) if options.include?(:proxy)
            validate_proxy_settings!
          end
          
          def extract_server!
            self[:server] = options.delete(:server) || DEFAULT_HOST
          end

          def extract_port!
            self[:port] = options.delete(:port) || (options[:use_ssl] ? 443 : 80)
          end
          
          def extract_remainder!
            update(options)
          end
          
          def validate!
            invalid_options = options.keys.select {|key| !self.class.valid_options.include?(key)}
            raise InvalidConnectionOption.new(invalid_options) unless invalid_options.empty?
          end
          
          def validate_proxy_settings!
            if connecting_through_proxy? && missing_proxy_settings?
              raise ArgumentError, "Missing proxy settings. Must specify at least :host."
            end
          end
      end
    end
  end
end
