# encoding: utf-8
require "logstash/outputs/base"
require "mqtt"

# This is Logstash output plugin for the http://mqtt.org/[MQTT] protocol.
#
# Features:
#
# * Publish messages to a topic
# * TSL/SSL connection to MQTT server (optional)
# * Message publishing to a topic
# * QoS levels 0 and 1 (note that QoS 2 is not currently supported due to https://github.com/njh/ruby-mqtt[ruby-mqtt] library limitations)
# * Fault tolerance for network shortages, however not optimzied for performance since it takes a new connection for each event (or a bunch of events) to be published
# * MQTT protocol version 3.1.0
#
# Example publishing to test.mosquitto.org:
# [source,ruby]
# ----------------------------------
# output {
#   mqtt {
#     host => "test.mosquitto.org"
#     port => 8883
#     topic => "hello"
#   }
# }
# ----------------------------------
#
# Example publishing to https://aws.amazon.com/iot/[AWS IoT]:
# [source,ruby]
# ----------------------------------
# output {
#   mqtt {
#     host => "somehostname.iot.someregion.amazonaws.com"
#     port => 8883
#     topic => "hello"
#     client_id => "clientidfromaws"
#     ssl => true
#     cert_file => "certificate.pem.crt"
#     key_file => "private.pem.key"
#     ca_file => "root-CA.crt"
#   }
# }
# ----------------------------------
#
# Topic may also depend on parts of the event using the standard sprintf syntax.
# [source,ruby]
# ----------------------------------
# output {
#   mqtt {
#     ...
#     topic => "something/%{myfield}"
#   }
# }
# ----------------------------------

class LogStash::Outputs::MQTT < LogStash::Outputs::Base

  config_name "mqtt2"

  # The default codec for this plugin is JSON. You can override this to suit your particular needs however.
  default :codec, "json"

  # MQTT server host name
  config :host, :validate => :string, :required => true

  # Port to connect to
  config :port, :validate => :number, :default => 8883

  # Topic that the messages will be published to
  config :topic, :validate => :string, :required => true

  # Retain flag of the published message
  # If true, the message will be stored by the server and be sent immediately to each subscribing client
  # so that the subscribing client doesn't have to wait until a publishing client sends the next update
  config :retain, :validate => :boolean, :default => false

  # QoS of the published message, can be either 0 (at most once) or 1 (at least once)
  config :qos, :validate => :number, :default => 0

  # Client identifier (generated automatically if not given)
  config :client_id, :validate => :string

  # Username to authenticate to the server with
  config :username, :validate => :string

  # Password to authenticate to the server with
  config :password, :validate => :string

  # Set to true to enable SSL/TLS encrypted communication
  config :ssl, :validate => :boolean, :default => false

  # Client certificate file used to SSL/TLS communication
  config :cert_file, :validate => :path

  # Private key file associated with the client certificate
  config :key_file, :validate => :path

  # Root CA certificate
  config :ca_file, :validate => :path

  # Time in seconds to wait before retrying a connection
  config :connect_retry_interval, :validate => :number, :default => 10

  # Time Keep alive connexion between ping to remote servers
  config :keep_alive, :validate => :number, :default => 15


  public
  def register
    @options = {
      :host => @host
    }
    if @port
      @options[:port] = @port
    end
    if @client_id
      @options[:client_id] = @client_id
    end
    if @username
      @options[:username] = @username
    end
    if @password
      @options[:password] = @password
    end
    if @ssl
      @options[:ssl] = @ssl
    end
    if @cert_file
      @options[:cert_file] = @cert_file
    end
    if @key_file
      @options[:key_file] = @key_file
    end
    if @ca_file
      @options[:ca_file] = @ca_file
    end
    if @keep_alive
      @options[:keep_alive] = @keep_alive
    end

    # Encode events using the given codec
    # Use an array as a buffer so the multi_receive can handle multiple events with a single connection
    @event_buffer = Array.new
    @codec.on_event do |event, encoded_event|
      @event_buffer.push([event, encoded_event])
    end
  end # def register
  public
  def receive(event)
    @codec.encode(event)
    handle_events
  end # def receive

  def multi_receive(events)
    events.each { |event| @codec.encode(event) }
    # Handle all events at once to prevent taking a new connection for each event
    handle_events
  end

  def close
    @closing = true
  end # def close

  private

  def mqtt_client
    @logger.debug("Connecting MQTT with options #{@options}")
    @mqtt_client ||= MQTT::Client.connect(@options)
  end

  def handle_events
    # It is easy to cope with network failures, ie. if connection fails just try it again
    while event = @event_buffer.first do
      @logger.debug("Publishing MQTT event #{event[1]} with topic #{@topic}, retain #{@retain}, qos #{@qos}")
      mqtt_client.publish(event[0].sprintf(@topic), event[1], @retain, @qos)
      @event_buffer.shift
    end
  rescue StandardError => e
    @logger.error("Error #{e.message} while publishing to MQTT server. Will retry in #{@connect_retry_interval} seconds.")
    @mqtt_client = nil
    Stud.stoppable_sleep(@connect_retry_interval, 1) { @closing }
    retry
  end # def handle_event
end # class LogStash::Outputs::MQTT2