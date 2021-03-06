begin
  require 'net/https'
rescue LoadError
  warn "Warning: no such file to load -- net/https. Make sure openssl is installed if you want ssl support"
  require 'net/http'
end

module Faraday
  class Adapter
    class NetHttp < Faraday::Adapter
      NET_HTTP_EXCEPTIONS = [
        EOFError,
        Errno::ECONNABORTED,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EINVAL,
        Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError,
        Net::ProtocolError,
        SocketError,
        Zlib::GzipFile::Error,
      ]

      NET_HTTP_EXCEPTIONS << OpenSSL::SSL::SSLError if defined?(OpenSSL)

      def call(env)
        super
        http = net_http_connection(env)
        configure_ssl(http, env[:ssl]) if env[:url].scheme == 'https' and env[:ssl]

        req = env[:request]
        http.read_timeout = http.open_timeout = req[:timeout] if req[:timeout]
        http.open_timeout = req[:open_timeout]                if req[:open_timeout]

        begin
          http_response = perform_request(http, env)
        rescue *NET_HTTP_EXCEPTIONS
          raise Error::ConnectionFailed, $!
        end

        save_response(env, http_response.code.to_i, http_response.body || '') do |response_headers|
          http_response.each_header do |key, value|
            response_headers[key] = value
          end
        end

        @app.call env
      rescue Timeout::Error => err
        raise Faraday::Error::TimeoutError, err
      end

      def create_request(env)
        request = Net::HTTPGenericRequest.new \
          env[:method].to_s.upcase,    # request method
          !!env[:body],                # is there request body
          :head != env[:method],       # is there response body
          env[:url].request_uri,       # request uri path
          env[:request_headers]        # request headers

        if env[:body].respond_to?(:read)
          request.body_stream = env[:body]
        else
          request.body = env[:body]
        end
        request
      end

      def perform_request(http, env)
        if :get == env[:method] and !env[:body]
          # prefer `get` to `request` because the former handles gzip (ruby 1.9)
          http.get env[:url].request_uri, env[:request_headers]
        else
          http.request create_request(env)
        end
      end

      def net_http_connection(env)
        if proxy = env[:request][:proxy]
          Net::HTTP::Proxy(proxy[:uri].host, proxy[:uri].port, proxy[:user], proxy[:password])
        else
          Net::HTTP
        end.new(env[:url].host, env[:url].port)
      end

      def configure_ssl(http, ssl)
        http.use_ssl      = true
        http.verify_mode  = ssl_verify_mode(ssl)
        http.cert_store   = ssl_cert_store(ssl)

        http.cert         = ssl[:client_cert]  if ssl[:client_cert]
        http.key          = ssl[:client_key]   if ssl[:client_key]
        http.ca_file      = ssl[:ca_file]      if ssl[:ca_file]
        http.ca_path      = ssl[:ca_path]      if ssl[:ca_path]
        http.verify_depth = ssl[:verify_depth] if ssl[:verify_depth]
        http.ssl_version  = ssl[:version]      if ssl[:version]
      end

      def ssl_cert_store(ssl)
        return ssl[:cert_store] if ssl[:cert_store]
        # Use the default cert store by default, i.e. system ca certs
        cert_store = OpenSSL::X509::Store.new
        cert_store.set_default_paths
        cert_store
      end

      def ssl_verify_mode(ssl)
        ssl[:verify_mode] || begin
          if ssl.fetch(:verify, true)
            OpenSSL::SSL::VERIFY_PEER
          else
            OpenSSL::SSL::VERIFY_NONE
          end
        end
      end
    end
  end
end
