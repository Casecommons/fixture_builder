require 'active_support/core_ext/string/inflections'
require 'digest/md5'
require 'fileutils'

module FixtureBuilder
  class Configuration
    attr_accessor :select_sql, :delete_sql, :skip_tables, :files_to_check, :record_name_fields, :fixture_builder_file, :after_build, :quiet

    SCHEMA_FILES = ['db/schema.rb', 'db/development_structure.sql', 'db/test_structure.sql', 'db/production_structure.sql']

    def initialize
      @quiet = false
      @custom_names = {}
      @model_name_procs = {}
      @file_hashes = file_hashes
    end

    def include(*args)
      class_eval do
        args.each do |arg|
          include arg
        end
      end
    end

    def select_sql
      @select_sql ||= "SELECT * FROM %s"
    end

    def delete_sql
      @delete_sql ||= "DELETE FROM %s"
    end

    def skip_tables
      @skip_tables ||= %w{ schema_migrations }
    end

    def files_to_check
      @files_to_check ||= schema_definition_files
    end

    def schema_definition_files
      Dir['db/*'].inject([]) do |result, file|
        result << file if SCHEMA_FILES.include?(file)
        result
      end
    end

    def files_to_check=(files)
      @files_to_check = files
      @file_hashes = file_hashes
      @files_to_check
    end

    def record_name_fields
      @record_name_fields ||= %w{ unique_name display_name name title username login }
    end

    def fixture_builder_file
      @fixture_builder_file ||= ::Rails.root.join('tmp', 'fixture_builder.yml')
    end

    def factory(&block)
      return unless rebuild_fixtures?
      say "Building fixtures"
      delete_tables
      delete_yml_files
      surface_errors { instance_eval(&block) }
      FileUtils.rm_rf(::Rails.root.join(spec_or_test_dir, 'fixtures', '*.yml'))
      dump_empty_fixtures_for_all_tables
      dump_tables
      write_config
      after_build.call if after_build
    end

    def name_model_with(model_class, &block)
      @model_name_procs[model_class.table_name] = block
    end

    def name(custom_name, *model_objects)
      raise "Cannot name an object blank" unless custom_name.present?
      model_objects.each do |model_object|
        raise "Cannot name a blank object" unless model_object.present?
        key = [model_object.class.table_name, model_object.id]
        raise "Cannot set name for #{key.inspect} object twice" if @custom_names[key]
        @custom_names[key] = custom_name
        model_object
      end
    end

    private

    def say(*messages)
      print_out messages.map { |message| "=> #{message}" }
    end

    def print_out(message = "")
      puts message unless quiet
    end

    def surface_errors
      yield
    rescue Object => error
      print_out
      say "There was an error building fixtures", error.inspect
      print_out
      print_out error.backtrace
      print_out
      exit!
    end

    def delete_tables
      tables.each { |t| ActiveRecord::Base.connection.delete(delete_sql % ActiveRecord::Base.connection.quote_table_name(t)) }
    end

    def delete_yml_files
      FileUtils.rm(Dir.glob(fixtures_dir('*.yml')))
    end

    def tables
      ActiveRecord::Base.connection.tables - skip_tables
    end

    def record_name(record_hash, table_name)
      key = [table_name, record_hash['id'].to_i]
      name = case
      when name_proc = @model_name_procs[table_name]
        name_proc.call(record_hash, @row_index.succ!)
      when custom = @custom_names[key]
        custom
      else
        inferred_record_name(record_hash, table_name)
      end
      @record_names << name
      name.to_s
    end

    def inferred_record_name(record_hash, table_name)
      record_name_fields.each do |try|
        if name = record_hash[try]
          inferred_name = name.underscore.gsub(/\W/, ' ').squeeze(' ').tr(' ', '_')
          count = @record_names.select { |name| name.to_s.starts_with?(inferred_name) }.size
          # CHANGED == to starts_with?
          return count.zero? ? inferred_name : "#{inferred_name}_#{count}"
        end
      end
      [table_name, @row_index.succ!].join('_')
    end

    def dump_empty_fixtures_for_all_tables
      tables.each do |table_name|
        write_fixture_file({}, table_name)
      end
    end

    def dump_tables
      fixtures = tables.inject([]) do |files, table_name|
        table_klass = table_name.classify.constantize rescue nil
        if table_klass
          rows = table_klass.unscoped.all.collect(&:attributes)
        else
          rows = ActiveRecord::Base.connection.select_all(select_sql % ActiveRecord::Base.connection.quote_table_name(table_name))
        end
        next files if rows.empty?

        @row_index      = '000'
        @record_names = []
        fixture_data = rows.inject({}) do |hash, record|
          hash.merge(record_name(record, table_name) => record)
        end
        write_fixture_file fixture_data, table_name

        files + [File.basename(fixture_file(table_name))]
      end
      say "Built #{fixtures.to_sentence}"
    end

    def write_fixture_file(fixture_data, table_name)
      File.open(fixture_file(table_name), 'w') do |file|
        file.write fixture_data.to_yaml
      end
    end

    def fixture_file(table_name)
      fixtures_dir("#{table_name}.yml")
    end

    def fixtures_dir(path = '')
      File.expand_path(File.join(::Rails.root, spec_or_test_dir, 'fixtures', path))
    end

    def spec_or_test_dir
      File.exists?(File.join(::Rails.root, 'spec')) ? 'spec' : 'test'
    end

    def file_hashes
      files_to_check.inject({}) do |hash, filename|
        hash[filename] = Digest::MD5.hexdigest(File.read(filename))
        hash
      end
    end

    def read_config
      return {} unless File.exist?(fixture_builder_file)
      YAML.load_file(fixture_builder_file)
    end

    def write_config
      FileUtils.mkdir_p(File.dirname(fixture_builder_file))
      File.open(fixture_builder_file, 'w') { |f| f.write(YAML.dump(@file_hashes)) }
    end

    def rebuild_fixtures?
      @file_hashes != read_config
    end
  end
end
