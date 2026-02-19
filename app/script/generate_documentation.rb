#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "time"
require_relative "../config/environment"

module DocumentationGenerator
  module_function

  ROOT_PATH = Rails.root.join("..").expand_path.freeze
  OPENAPI_PATH = ROOT_PATH.join("docs", "openapi", "v1.yaml").freeze
  API_REFERENCE_PATH = ROOT_PATH.join("docs", "api_reference.md").freeze
  DATABASE_MODEL_PATH = ROOT_PATH.join("docs", "database_model.md").freeze
  EXCLUDED_TABLES = %w[schema_migrations ar_internal_metadata].freeze
  HTTP_METHOD_ORDER = %w[get post put patch delete options head].freeze

  def run!
    generate_api_reference!
    generate_database_model!

    puts "Generated #{API_REFERENCE_PATH}"
    puts "Generated #{DATABASE_MODEL_PATH}"
  end

  def generate_api_reference!
    spec = YAML.safe_load(File.read(OPENAPI_PATH), aliases: true) || {}
    endpoints = collect_endpoints(spec)
    schemas = spec.fetch("components", {}).fetch("schemas", {}).keys.sort

    markdown = []
    markdown << "# API Reference"
    markdown << ""
    markdown << "Generated at: #{Time.current.iso8601}"
    markdown << "Source contract: `docs/openapi/v1.yaml`"
    markdown << ""
    markdown << "## Authentication"
    markdown << ""
    markdown << "- Partner endpoints use Bearer token authentication."
    markdown << "- Mutating endpoints require `Idempotency-Key`."
    markdown << "- All monetary/rate fields must be sent as strings."
    markdown << ""
    markdown << "## Endpoints"
    markdown << ""
    markdown << "| Method | Path | Operation ID | Summary | Idempotency | Responses |"
    markdown << "| --- | --- | --- | --- | --- | --- |"
    endpoints.each do |entry|
      markdown << "| `#{entry[:method]}` | `#{entry[:path]}` | `#{entry[:operation_id]}` | #{entry[:summary]} | #{entry[:idempotency_required]} | #{entry[:responses]} |"
    end
    markdown << ""
    markdown << "## Schemas"
    markdown << ""
    schemas.each do |schema|
      markdown << "- `#{schema}`"
    end
    markdown << ""

    File.write(API_REFERENCE_PATH, markdown.join("\n"))
  end

  def collect_endpoints(spec)
    paths = spec.fetch("paths", {})
    entries = []

    paths.keys.sort.each do |path|
      operations = paths.fetch(path, {})
      ordered_methods = operations.keys.sort_by do |method|
        [ HTTP_METHOD_ORDER.index(method.to_s) || HTTP_METHOD_ORDER.length, method.to_s ]
      end

      ordered_methods.each do |method|
        operation = operations.fetch(method, {})
        next unless operation.is_a?(Hash)

        responses = operation.fetch("responses", {}).keys.sort.join(", ")
        entries << {
          method: method.to_s.upcase,
          path: path,
          operation_id: operation.fetch("operationId", "-"),
          summary: sanitize_markdown(operation.fetch("summary", "-")),
          idempotency_required: idempotency_required?(operation) ? "Yes" : "No",
          responses: responses.presence || "-"
        }
      end
    end

    entries
  end

  def idempotency_required?(operation)
    Array(operation["parameters"]).any? do |param|
      next true if param.is_a?(Hash) && param["$ref"] == "#/components/parameters/IdempotencyKey"

      param.is_a?(Hash) && param["name"] == "Idempotency-Key"
    end
  end

  def sanitize_markdown(value)
    value.to_s.gsub("|", "\\|")
  end

  def generate_database_model!
    connection = ActiveRecord::Base.connection
    tables = connection.tables.reject { |table| EXCLUDED_TABLES.include?(table) }.sort
    foreign_keys = load_foreign_keys(connection)
    rls_map = load_rls_map(connection)
    policy_map = load_rls_policy_map(connection)
    append_only_tables = load_append_only_tables(connection)

    markdown = []
    markdown << "# Database Model Documentation"
    markdown << ""
    markdown << "Generated at: #{Time.current.iso8601}"
    markdown << "Source schema: `app/db/structure.sql`"
    markdown << ""
    markdown << "## Summary"
    markdown << ""
    markdown << "- Total tables documented: #{tables.size}"
    markdown << "- Tables with append-only mutation guard: #{append_only_tables.size}"
    markdown << "- Business timezone: `America/Sao_Paulo`"
    markdown << ""

    tables.each do |table|
      markdown.concat(render_table_section(
        connection: connection,
        table: table,
        foreign_keys: foreign_keys.fetch(table, {}),
        rls: rls_map.fetch(table, { "enabled" => false, "forced" => false }),
        policies: policy_map.fetch(table, []),
        append_only: append_only_tables.include?(table)
      ))
    end

    File.write(DATABASE_MODEL_PATH, markdown.join("\n"))
  end

  def render_table_section(connection:, table:, foreign_keys:, rls:, policies:, append_only:)
    columns = connection.columns(table)
    indexes = connection.indexes(table)
    check_constraints = connection.check_constraints(table)
    primary_key = connection.primary_key(table)

    section = []
    section << "## `#{table}`"
    section << ""
    section << "- Primary key: `#{primary_key || '-'}`
- RLS enabled: `#{rls.fetch("enabled")}`
- RLS forced: `#{rls.fetch("forced")}`
- Append-only guard: `#{append_only}`"
    section << ""

    unless policies.empty?
      section << "- Policies:"
      policies.each do |policy|
        section << "  - `#{policy.fetch("policy_name")}`"
      end
      section << ""
    end

    section << "### Columns"
    section << ""
    section << "| Column | SQL Type | Null | Default | FK |"
    section << "| --- | --- | --- | --- | --- |"
    columns.each do |column|
      fk = foreign_keys[column.name]
      fk_label = fk ? "`#{fk.fetch("foreign_table")}.#{fk.fetch("foreign_column")}`" : "-"
      section << "| `#{column.name}` | `#{column.sql_type}` | #{column.null} | `#{column.default}` | #{fk_label} |"
    end
    section << ""

    unless check_constraints.empty?
      section << "### Check Constraints"
      section << ""
      check_constraints.each do |constraint|
        section << "- `#{constraint.name}`: `#{constraint.expression}`"
      end
      section << ""
    end

    unless indexes.empty?
      section << "### Indexes"
      section << ""
      indexes.each do |index|
        unique = index.unique ? "unique" : "non-unique"
        where_clause = index.where.present? ? " WHERE #{index.where}" : ""
        columns = index.columns.is_a?(Array) ? index.columns : [ index.columns ]
        column_list = columns.compact.map(&:to_s).join(", ")
        section << "- `#{index.name}` (#{unique}): `#{column_list}`#{where_clause}"
      end
      section << ""
    end

    section
  end

  def load_foreign_keys(connection)
    rows = connection.select_all(<<~SQL)
      SELECT
        tc.table_name AS table_name,
        kcu.column_name AS column_name,
        ccu.table_name AS foreign_table_name,
        ccu.column_name AS foreign_column_name
      FROM information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu
        ON tc.constraint_name = kcu.constraint_name
       AND tc.table_schema = kcu.table_schema
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_name = tc.constraint_name
       AND ccu.table_schema = tc.table_schema
      WHERE tc.constraint_type = 'FOREIGN KEY'
        AND tc.table_schema = 'public'
    SQL

    rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, memo|
      memo[row["table_name"]][row["column_name"]] = {
        "foreign_table" => row["foreign_table_name"],
        "foreign_column" => row["foreign_column_name"]
      }
    end
  end

  def load_rls_map(connection)
    rows = connection.select_all(<<~SQL)
      SELECT
        c.relname AS table_name,
        c.relrowsecurity AS rls_enabled,
        c.relforcerowsecurity AS rls_forced
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind = 'r'
    SQL

    rows.each_with_object({}) do |row, memo|
      memo[row["table_name"]] = {
        "enabled" => row["rls_enabled"],
        "forced" => row["rls_forced"]
      }
    end
  end

  def load_rls_policy_map(connection)
    rows = connection.select_all(<<~SQL)
      SELECT tablename, policyname
      FROM pg_policies
      WHERE schemaname = 'public'
      ORDER BY tablename, policyname
    SQL

    rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, memo|
      memo[row["tablename"]] << { "policy_name" => row["policyname"] }
    end
  end

  def load_append_only_tables(connection)
    rows = connection.select_values(<<~SQL)
      SELECT DISTINCT tgrelid::regclass::text
      FROM pg_trigger
      WHERE NOT tgisinternal
        AND tgfoid = 'app_forbid_mutation()'::regprocedure
    SQL

    rows.map { |name| name.split(".").last }
  end
end

DocumentationGenerator.run!
