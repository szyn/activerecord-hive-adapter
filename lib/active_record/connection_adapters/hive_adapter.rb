require 'active_record/connection_adapters/abstract_adapter'
require 'arel/visitors/bind_visitor'
require 'rbhive'
require 'json'

module Arel
  module Visitors
    class Hive < Arel::Visitors::ToSql
      def visit_Arel_Nodes_InsertStatement o, a
        [
          "INSERT INTO TABLE #{visit o.relation, a}",
          (visit o.values if o.values),
        ].compact.join ' '
      end

      def visit_Arel_Nodes_Values o, a
        "SELECT (#{o.expressions.zip(o.columns).map { |value, attr|
          if Nodes::SqlLiteral === value
            visit value, a
          else
            quote(value, attr && column_for(attr))
          end
        }.join ', '}) FROM dual"
      end
    end
  end
end

module ActiveRecord
  module ConnectionHandling # :nodoc:
    # hive adapter reuses sqlite_connection.
    def hive_connection(config)
      # Require database.
      unless config[:database]
        raise ArgumentError, "No database file specified. Missing argument: database"
      end

      params = {}
      if config.has_key?(:transport)
        params[:transport] = config[:transport].to_sym
        params[:sasl_params] = config[:sasl_params] || {} if 'sasl' == config[:transport].to_s
      end

      connection = RBHive::TCLIConnection.new(config[:host], config[:port] || 10_000, params, logger)
      connection.open
      connection.open_session

      ConnectionAdapters::HiveAdapter.new(connection, logger, config)
    end
  end

  module ConnectionAdapters
    class HiveAdapter < AbstractAdapter
      attr_reader :dual

      NATIVE_DATABASE_TYPES = {
        :array       => { :name => "ARRAY<STRING>" }, 
        :boolean     => { :name => "BOOLEAN" },
        :date        => { :name => "TIMESTAMP" },
        :datetime    => { :name => "TIMESTAMP" },
        :double      => { :name => "DOUBLE" },
        :float       => { :name => "FLOAT" },
        :integer     => { :name => "INT" },
        :map         => { :name => "MAP<STRING, STRING>" },
        :primary_key => "INT",
        :text        => { :name => "STRING" },
        :string      => { :name => "STRING"},
        :time        => { :name => "TIMESTAMP" },
        :timestamp   => { :name => "TIMESTAMP" },
      }

      class ColumnDefinition < ActiveRecord::ConnectionAdapters::ColumnDefinition
        attr_accessor :partition
      end

      class SchemaCreation < AbstractAdapter::SchemaCreation
        private

        def visit_TableDefinition(o)
          create_sql = "CREATE#{' TEMPORARY' if o.temporary} TABLE "
          create_sql << "#{quote_table_name(o.name)} ("
          create_sql << o.columns.map { |c| accept c }.join(', ')
          create_sql << ") "

          if o.partitions.any?
            create_sql << "PARTITIONED BY ("
            create_sql << o.partitions.map { |c| accept c }.join(', ')
            create_sql << ") "
          end

          create_sql << "#{o.options}"

          create_sql
        end
      end

      class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition
        def column(name, type = nil, options = {})
          super

          column = self[name]
          column.partition = options[:partition]

          self
        end

        def columns
          @columns_hash.values.reject { |c| c.partition }
        end

        def partitions
          @columns_hash.values.select { |c| c.partition }
        end

        [:array, :map].each do |column_type|
          define_method column_type do |*args|
            options = args.extract_options!
            column_names = args
            column_names.each { |name| column(name, column_type, options) }
          end
        end

        private

        def create_column_definition(name, type)
          ColumnDefinition.new name, type
        end
      end

      class BindSubstitution < Arel::Visitors::Hive # :nodoc:
        include Arel::Visitors::BindVisitor
      end

      def initialize(connection, logger, config)
        super(connection, logger)

        @config = config
        @dual = config[:dual] || "dual"
        @visitor = unprepared_visitor

        execute("USE #{config[:database]}")

        # initialize_dual_table
      end

      def adapter_name
        "Hive"
      end

      def add_column_options!(sql, options) #:nodoc:
        comments = options.dup.delete_if { |k, value|
          !%w(default null requested_type type partition).include?(k.to_s)
        }
        # Stuffing args we can't work with now in Hive into a comment
        sql << " COMMENT #{quote(comments.to_json)}" if comments.size > 0
      end

      def add_index(table_name, column_name, options = {}) #:nodoc:
        index_name, index_type, index_columns, index_options, index_algorithm, index_using = add_index_options(table_name, column_name, options)
        index_algorithm ||= "'org.apache.hadoop.hive.ql.index.compact.CompactIndexHandler'"

        execute(%{CREATE INDEX #{quote_column_name(index_name)} #{index_using} 
                  ON TABLE #{quote_table_name(table_name)} (#{index_columns}) #{index_options}
                  AS #{index_algorithm}
                  WITH DEFERRED REBUILD})
      end

      def columns(table, name = nil)
        results = select_rows("DESCRIBE #{table}")

        cols = results.collect { |r|
          column_name = r[:col_name]
          sql_type = r[:data_type]
          comment = nil
          column_details = JSON.parse(comment || "{}").symbolize_keys
          default = column_details[:default]
          null = column_details[:null].nil?

          Column.new(column_name, default, sql_type, null)
        }

        cols
      end

      LIMIT_OFFSET_REG = /\slimit\s+(\d+)\s+offset\s+(\d+)/i

      def execute(query, name = nil)
        if query =~ LIMIT_OFFSET_REG
          limit, offset = query.scan(LIMIT_OFFSET_REG).flatten.map(&:to_i)
          if offset > 0
            result = @connection.fetch(query.sub(LIMIT_OFFSET_REG, " LIMIT #{limit + offset}"))
            result.slice!(0, offset)
            return result
          else
            query = query.sub(LIMIT_OFFSET_REG, " LIMIT #{limit}")
          end
        end
        @connection.fetch(query)
      end

      def exec_query(sql, name = 'SQL', binds = [])
        result = execute(sql, name)
        column_names = result.column_names.collect {|x| x.to_s}
        values = result.as_arrays

        ActiveRecord::Result.new(column_names, values)
      end

      def exec_insert(sql, name, binds, pk = nil, sequence_name = nil)
        execute to_sql(sql, binds), name
      end

      def indexes(table_name, name = nil)
        []
      end

      def initialize_dual_table
        # unless table_exists?(dual)
        #   execute(%{CREATE TABLE #{dual} (dummy STRING)})
        #   execute(%{LOAD DATA LOCAL INPATH '/etc/hosts' OVERWRITE INTO TABLE #{dual}})
        #   execute(%{INSERT OVERWRITE TABLE #{dual} SELECT 1 FROM #{dual} LIMIT 1})
        # end
      end
 
      def last_inserted_id(result)
        # TODO
      end

      def native_database_types
        NATIVE_DATABASE_TYPES
      end

      def primary_key(table)
        column = columns(table).find { |c|
          !c.primary 
        }

        column && column.name
      end

      def quote_column_name(name) #:nodoc:
        %Q(#{name.to_s.gsub('"', '""')})
      end

      def schema_creation
        SchemaCreation.new self
      end

      def select(sql, name = nil, binds = [])
        exec_query(sql, name, binds)
      end

      def select_in_batch(sql, batch = 1000, &block)        
        @connection.fetch_in_batch(sql, batch) do |result_set|
          block.yield(result_set)
        end
      end

      def select_rows(query, name = nil)
        execute(query)
      end

      def supports_migrations?
        true
      end

      def tables(name = nil)
        results = select_rows("SHOW TABLES")
        results.collect { |t| t.values.first }
      end

      def table_exists?(table_name)
        table_name = table_name.to_s
        select_rows("SHOW TABLES").any? { |table| table[:tableName] == table_name }
      end

      # Maps logical Rails types to Hive-specific data types.
      def type_to_sql(type, limit = nil, precision = nil, scale = nil)
        return case limit
          when 1; 'TINYINT'
          when 2; 'SMALLINT'
          when nil, 3, 4; 'INT'
          when 5..8; 'BIGINT'
          else raise(ActiveRecordError, "No integer type has byte size #{limit}")
        end if type == :integer
        super
      end

      protected

      def create_table_definition(name, temporary, options)
        TableDefinition.new native_database_types, name, temporary, options
      end
    end
  end
end
