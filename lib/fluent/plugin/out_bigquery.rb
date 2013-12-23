# -*- coding: utf-8 -*-

require 'fluent/plugin/bigquery/version'

require 'fluent/mixin/config_placeholders'
require 'fluent/mixin/plaintextformatter'

## TODO: load implementation
# require 'fluent/plugin/bigquery/load_request_body_wrapper'

require 'fluent/plugin/output_try_flush_interval_patch'

module Fluent
  ### TODO: error classes for each api error responses
  # class BigQueryAPIError < StandardError
  # end

  class BigQueryOutput < BufferedOutput
    Fluent::Plugin.register_output('bigquery', self)

    # https://developers.google.com/bigquery/browser-tool-quickstart
    # https://developers.google.com/bigquery/bigquery-api-quickstart

    config_set_default :buffer_type, 'lightening'

    config_set_default :flush_interval, 0.25
    config_set_default :try_flush_interval, 0.05

    config_set_default :buffer_chunk_records_limit, 100
    config_set_default :buffer_chunk_limit, 1000000
    config_set_default :buffer_queue_limit, 1024

    ### for loads
    ### TODO: different default values for buffering between 'load' and insert
    # config_set_default :flush_interval, 1800 # 30min => 48 imports/day
    # config_set_default :buffer_chunk_limit, 1000**4 # 1.0*10^12 < 1TB (1024^4)

    ### OAuth credential
    # config_param :client_id, :string
    # config_param :client_secret, :string

    ### Service Account credential
    config_param :email, :string
    config_param :private_key_path, :string
    config_param :private_key_passphrase, :string, :default => 'notasecret'

    # see as simple reference
    #   https://github.com/abronte/BigQuery/blob/master/lib/bigquery.rb
    config_param :project, :string

    # dataset_name
    #   The name can be up to 1,024 characters long, and consist of A-Z, a-z, 0-9, and the underscore,
    #   but it cannot start with a number or underscore, or have spaces.
    config_param :dataset, :string

    # table_id
    #   In Table ID, enter a name for your new table. Naming rules are the same as for your dataset.
    config_param :table, :string, :default => nil
    config_param :tables, :string, :default => nil

    config_param :field_string,  :string, :default => nil
    config_param :field_integer, :string, :default => nil
    config_param :field_float,   :string, :default => nil
    config_param :field_boolean, :string, :default => nil
    ### TODO: record field stream inserts doesn't works well?
    ###  At table creation, table type json + field type record -> field type validation fails
    ###  At streaming inserts, schema cannot be specified
    # config_param :field_record,  :string, :defualt => nil
    # config_param :optional_data_field, :string, :default => nil

    config_param :time_format, :string, :default => nil
    config_param :localtime, :bool, :default => nil
    config_param :utc, :bool, :default => nil
    config_param :time_field, :string, :default => nil

    config_param :method, :string, :default => 'insert' # or 'load' # TODO: not implemented now

    config_param :load_size_limit, :integer, :default => 1000**4 # < 1TB (1024^4) # TODO: not implemented now
    ### method: 'load'
    #   https://developers.google.com/bigquery/loading-data-into-bigquery
    # Maximum File Sizes:
    # File Type   Compressed   Uncompressed
    # CSV         1 GB         With new-lines in strings: 4 GB
    #                          Without new-lines in strings: 1 TB
    # JSON        1 GB         1 TB

    config_param :row_size_limit, :integer, :default => 100*1000 # < 100KB # configurable in google ?
    # config_param :insert_size_limit, :integer, :default => 1000**2 # < 1MB
    # config_param :rows_per_second_limit, :integer, :default => 1000 # spike limit
    ### method: ''Streaming data inserts support
    #  https://developers.google.com/bigquery/streaming-data-into-bigquery#usecases
    # Maximum row size: 100 KB
    # Maximum data size of all rows, per insert: 1 MB
    # Maximum rows per second: 100 rows per second, per table, with allowed and occasional bursts of up to 1,000 rows per second.
    #                          If you exceed 100 rows per second for an extended period of time, throttling might occur.
    ### Toooooooooooooo short/small per inserts and row!

    ### Table types
    # https://developers.google.com/bigquery/docs/tables
    #
    # type - The following data types are supported; see Data Formats for details on each data type:
    # STRING
    # INTEGER
    # FLOAT
    # BOOLEAN
    # RECORD A JSON object, used when importing nested records. This type is only available when using JSON source files.
    #
    # mode - Whether a field can be null. The following values are supported:
    # NULLABLE - The cell can be null.
    # REQUIRED - The cell cannot be null.
    # REPEATED - Zero or more repeated simple or nested subfields. This mode is only supported when using JSON source files.

    def initialize
      super
      require 'google/api_client'
      require 'google/api_client/client_secrets'
      require 'google/api_client/auth/installed_app'
    end

    def configure(conf)
      super

      if (!@table && !@tables) || (@table && @table)
        raise Fluent::ConfigError, "'table' or 'tables' must be specified, and both are invalid"
      end

      @tablelist = @tables ? @tables.split(',') : [@table]

      @fields = {}
      if @field_string
        @field_string.split(',').each do |fieldname|
          @fields[fieldname] = :string
        end
      end
      if @field_integer
        @field_integer.split(',').each do |fieldname|
          @fields[fieldname] = :integer
        end
      end
      if @field_float
        @field_float.split(',').each do |fieldname|
          @fields[fieldname] = :float
        end
      end
      if @field_boolean
        @field_boolean.split(',').each do |fieldname|
          @fields[fieldname] = :boolean
        end
      end

      if @localtime.nil?
        if @utc
          @localtime = false
        end
      end
      @timef = TimeFormatter.new(@time_format, @localtime)
    end

    def start
      super

      @bq = client.discovered_api("bigquery", "v2") # TODO: refresh with specified expiration
      @cached_client = nil
      @cached_client_expiration = nil

      @tables_queue = @tablelist.dup.shuffle
      @tables_mutex = Mutex.new
    end

    def shutdown
      super
      # nothing to do
    end

    def client
      return @cached_client if @cached_client && @cached_client_expiration > Time.now

      client = Google::APIClient.new(
        :application_name => 'Fluentd BigQuery plugin',
        :application_version => Fluent::BigQueryPlugin::VERSION
      )

      key = Google::APIClient::PKCS12.load_key( @private_key_path, @private_key_passphrase )
      asserter = Google::APIClient::JWTAsserter.new(
        @email,
        "https://www.googleapis.com/auth/bigquery",
        key
      )
      # refresh_auth
      client.authorization = asserter.authorize
      @cached_client_expiration = Time.now + 1800
      @cached_client = client
    end

    def insert(table_id, rows)
      res = client().execute(
        :api_method => @bq.tabledata.insert_all,
        :parameters => {
          'projectId' => @project,
          'datasetId' => @dataset,
          'tableId' => table_id,
        },
        :body_object => {
          "rows" => rows
        }
      )
      if res.status != 200
        # api_error? -> client cache clear
        @cached_client = nil

        message = res.body
        if res.body =~ /^\{/
          begin
            res_obj = JSON.parse(res.body)
            message = res_obj['error']['message'] || res.body
          rescue => e
            $log.warn "Parse error: google api error response body", :body => res.body
          end
        end
        $log.error "tabledata.insertAll API", :project_id => @project_id, :dataset => @dataset_id, :table => table_id, :code => res.status, :message => message
        raise "failed to insert into bigquery" # TODO: error class
      end
    end

    def load
      # https://developers.google.com/bigquery/loading-data-into-bigquery#loaddatapostrequest
      raise NotImplementedError # TODO
    end

    def format_record(record)
      out = {}
      @fields.each do |key, type|
        value = record[key]
        next if value.nil? # field does not exists, or null value
        out[key] = case type
                   when :string  then record[key].to_s
                   when :integer then record[key].to_i
                   when :float   then record[key].to_f
                   when :boolean then !!record[key]
                   # when :record
                   else
                     raise "BUG: unknown field type #{type}"
                   end
      end
      out
    end

    def format_stream(tag, es)
      super
      buf = ''
      es.each do |time, record|
        row = if @time_field
                format_record(record.merge({@time_field => @timef.format(time)}))
              else
                format_record(record)
              end
        buf << {"json" => row}.to_msgpack unless row.empty?
      end
      buf
    end

    def write(chunk)
      rows = []
      chunk.msgpack_each do |row_object|
        # TODO: row size limit
        rows << row_object
      end

      # TODO: method

      insert_table = @tables_mutex.synchronize do
        t = @tables_queue.shift
        @tables_queue.push t
        t
      end
      insert(insert_table, rows)
    end

    # def client_oauth # not implemented
    #   raise NotImplementedError, "OAuth needs browser authentication..."
    #
    #   client = Google::APIClient.new(
    #     :application_name => 'Example Ruby application',
    #     :application_version => '1.0.0'
    #   )
    #   bigquery = client.discovered_api('bigquery', 'v2')
    #   flow = Google::APIClient::InstalledAppFlow.new(
    #     :client_id => @client_id
    #     :client_secret => @client_secret
    #     :scope => ['https://www.googleapis.com/auth/bigquery']
    #   )
    #   client.authorization = flow.authorize # browser authentication !
    #   client
    # end
  end
end
