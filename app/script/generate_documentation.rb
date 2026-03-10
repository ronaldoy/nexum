#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "time"
require "json"
require "cgi"
require_relative "../config/environment"

module DocumentationGenerator
  module_function

  ROOT_PATH = Rails.root.join("..").expand_path.freeze
  OPENAPI_PATH = ROOT_PATH.join("docs", "openapi", "v1.yaml").freeze
  API_REFERENCE_PATH = ROOT_PATH.join("docs", "api_reference.md").freeze
  API_REFERENCE_HTML_PATH = ROOT_PATH.join("docs", "api_reference.html").freeze
  DATABASE_MODEL_PATH = ROOT_PATH.join("docs", "database_model.md").freeze
  EXCLUDED_TABLES = %w[schema_migrations ar_internal_metadata].freeze
  HTTP_METHOD_ORDER = %w[get post put patch delete options head].freeze

  def run!
    generate_api_reference!
    generate_api_reference_html!
    generate_database_model!

    puts "Generated #{API_REFERENCE_PATH}"
    puts "Generated #{API_REFERENCE_HTML_PATH}"
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

  def generate_api_reference_html!
    spec = YAML.safe_load(File.read(OPENAPI_PATH), aliases: true) || {}
    info = spec.fetch("info", {})
    endpoints = collect_endpoint_details(spec)
    grouped_endpoints = endpoints.group_by { |entry| entry[:tag] }
    schemas = spec.fetch("components", {}).fetch("schemas", {})

    File.write(
      API_REFERENCE_HTML_PATH,
      build_api_reference_html(
        info: info,
        endpoints: endpoints,
        grouped_endpoints: grouped_endpoints,
        schemas: schemas,
        generated_at: Time.current.iso8601
      )
    )
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

  def collect_endpoint_details(spec)
    paths = spec.fetch("paths", {})

    paths.keys.sort.flat_map do |path|
      operations = paths.fetch(path, {})
      ordered_methods = operations.keys.sort_by do |method|
        [ HTTP_METHOD_ORDER.index(method.to_s) || HTTP_METHOD_ORDER.length, method.to_s ]
      end

      ordered_methods.filter_map do |method|
        operation = operations.fetch(method, {})
        next unless operation.is_a?(Hash)

        tag = Array(operation["tags"]).first.presence || "General"
        request_body = resolve_reference(spec, operation["requestBody"])
        request_examples = extract_request_examples(spec, request_body)
        responses = collect_response_details(spec, operation.fetch("responses", {}))

        {
          anchor_id: endpoint_anchor_id(tag:, method:, path:),
          tag: tag,
          method: method.to_s.upcase,
          path: path,
          operation_id: operation.fetch("operationId", "-"),
          summary: operation.fetch("summary", "-"),
          description: operation.fetch("description", "").to_s.strip,
          authentication: authentication_label_for(path),
          idempotency_required: idempotency_required?(operation),
          parameters: collect_parameter_details(spec, operation.fetch("parameters", [])),
          request_bodies: collect_request_body_details(spec, request_body),
          request_examples: request_examples,
          responses: responses,
          search_text: [
            tag,
            method.to_s.upcase,
            path,
            operation.fetch("operationId", "-"),
            operation.fetch("summary", "-"),
            operation.fetch("description", "").to_s
          ].join(" ").downcase
        }
      end
    end
  end

  def idempotency_required?(operation)
    Array(operation["parameters"]).any? do |param|
      next true if param.is_a?(Hash) && param["$ref"] == "#/components/parameters/IdempotencyKey"

      param.is_a?(Hash) && param["name"] == "Idempotency-Key"
    end
  end

  def collect_parameter_details(spec, parameters)
    Array(parameters).filter_map do |parameter|
      resolved = resolve_reference(spec, parameter)
      next unless resolved.is_a?(Hash)

      {
        name: resolved.fetch("name", "-"),
        location: resolved.fetch("in", "-"),
        required: resolved["required"] ? "Yes" : "No",
        schema: schema_label(resolved["schema"]),
        description: resolved.fetch("description", "").to_s.strip
      }
    end
  end

  def collect_request_body_details(spec, request_body)
    resolved = resolve_reference(spec, request_body)
    return [] unless resolved.is_a?(Hash)

    content = resolved.fetch("content", {})

    content.keys.sort.map do |content_type|
      schema = content.dig(content_type, "schema")
      {
        content_type: content_type,
        required: resolved["required"] ? "Yes" : "No",
        schema: schema_label(schema)
      }
    end
  end

  def collect_response_details(spec, responses)
    responses.keys.sort.map do |status|
      resolved = resolve_reference(spec, responses.fetch(status))
      content = resolved.fetch("content", {})

      {
        status: status,
        description: resolved.fetch("description", "-"),
        content: content.keys.sort.map do |content_type|
          schema = content.dig(content_type, "schema")
          {
            content_type: content_type,
            schema: schema_label(schema)
          }
        end
      }
    end
  end

  def extract_request_examples(spec, request_body)
    resolved = resolve_reference(spec, request_body)
    return [] unless resolved.is_a?(Hash)

    resolved.fetch("content", {}).keys.sort.filter_map do |content_type|
      schema = resolved.dig("content", content_type, "schema")
      example = example_from_schema(spec, resolve_reference(spec, schema))
      next if example.blank?

      {
        content_type: content_type,
        body: JSON.pretty_generate(example)
      }
    end
  end

  def endpoint_anchor_id(tag:, method:, path:)
    [ slugify(tag), method.to_s.downcase, slugify(path) ].join("-")
  end

  def authentication_label_for(path)
    return "None" if %w[/health /ready].include?(path)
    return "Client credentials" if path.start_with?("/api/v1/oauth/token/")

    "Bearer token"
  end

  def sanitize_markdown(value)
    value.to_s.gsub("|", "\\|")
  end

  def build_api_reference_html(info:, endpoints:, grouped_endpoints:, schemas:, generated_at:)
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{escape_html(info.fetch("title", "API Reference"))}</title>
          <meta name="description" content="#{escape_html(info.fetch("summary", "API documentation"))}">
          <link rel="preconnect" href="https://fonts.googleapis.com">
          <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
          <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=Source+Sans+3:wght@400;600;700&display=swap" rel="stylesheet">
          <style>
            :root {
              --bg: #f4f2ee;
              --surface: rgba(255, 252, 245, 0.92);
              --surface-strong: #ffffff;
              --text: #172126;
              --muted: #5a6974;
              --line: rgba(17, 37, 46, 0.12);
              --brand: #0b5d63;
              --brand-soft: #d9edeb;
              --accent: #c96d21;
              --shadow: 0 18px 38px rgba(11, 34, 36, 0.10);
              --radius-lg: 24px;
              --radius-md: 18px;
              --radius-sm: 12px;
              --get: #176b5f;
              --post: #0b5d63;
              --put: #875e12;
              --patch: #8f3c22;
              --delete: #9d2f34;
            }

            * { box-sizing: border-box; }

            html {
              scroll-behavior: smooth;
            }

            body {
              margin: 0;
              min-height: 100vh;
              background:
                radial-gradient(circle at top right, rgba(11, 93, 99, 0.12), transparent 28%),
                radial-gradient(circle at left top, rgba(201, 109, 33, 0.10), transparent 24%),
                linear-gradient(180deg, #f7f4ef 0%, #f2ede6 100%);
              color: var(--text);
              font-family: "Source Sans 3", "Helvetica Neue", sans-serif;
            }

            a { color: inherit; }

            code, pre {
              font-family: "IBM Plex Mono", "SFMono-Regular", Consolas, monospace;
            }

            .page {
              width: min(1480px, calc(100% - 32px));
              margin: 0 auto;
              padding: 24px 0 56px;
            }

            .layout {
              display: grid;
              grid-template-columns: 320px minmax(0, 1fr);
              gap: 24px;
            }

            .panel {
              background: var(--surface);
              border: 1px solid var(--line);
              border-radius: var(--radius-lg);
              box-shadow: var(--shadow);
              backdrop-filter: blur(12px);
            }

            .sidebar {
              position: sticky;
              top: 24px;
              align-self: start;
              padding: 24px;
            }

            .kicker {
              display: inline-flex;
              align-items: center;
              gap: 8px;
              padding: 8px 12px;
              border-radius: 999px;
              background: rgba(11, 93, 99, 0.10);
              color: var(--brand);
              font-size: 0.84rem;
              font-weight: 700;
              letter-spacing: 0.08em;
              text-transform: uppercase;
            }

            .sidebar h1,
            .hero h2,
            .section h2,
            .endpoint-card h3,
            .schema-card summary {
              font-family: "Space Grotesk", "Avenir Next", sans-serif;
              letter-spacing: -0.02em;
            }

            .sidebar h1 {
              margin: 16px 0 8px;
              font-size: 2rem;
              line-height: 1;
            }

            .lede,
            .sidebar p,
            .meta-note {
              color: var(--muted);
              line-height: 1.55;
            }

            .meta-stack {
              display: grid;
              gap: 12px;
              margin: 24px 0;
            }

            .meta-chip {
              padding: 12px 14px;
              border-radius: var(--radius-md);
              background: rgba(255, 255, 255, 0.78);
              border: 1px solid var(--line);
            }

            .meta-chip strong {
              display: block;
              font-size: 0.78rem;
              text-transform: uppercase;
              letter-spacing: 0.08em;
              color: var(--brand);
              margin-bottom: 4px;
            }

            .sidebar-links,
            .tag-nav {
              display: grid;
              gap: 10px;
            }

            .sidebar-links a,
            .tag-nav a {
              text-decoration: none;
              padding: 10px 12px;
              border-radius: var(--radius-sm);
              border: 1px solid var(--line);
              background: rgba(255, 255, 255, 0.64);
              transition: transform 120ms ease, border-color 120ms ease, background 120ms ease;
            }

            .sidebar-links a:hover,
            .tag-nav a:hover {
              transform: translateY(-1px);
              border-color: rgba(11, 93, 99, 0.30);
              background: rgba(217, 237, 235, 0.62);
            }

            .content {
              display: grid;
              gap: 24px;
            }

            .hero,
            .section {
              padding: 28px;
            }

            .hero {
              display: grid;
              gap: 20px;
            }

            .hero h2 {
              margin: 0;
              font-size: clamp(2.2rem, 4vw, 3.7rem);
              line-height: 0.95;
              max-width: 12ch;
            }

            .hero-grid {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 14px;
            }

            .stat {
              padding: 18px;
              border-radius: var(--radius-md);
              background: linear-gradient(180deg, rgba(255, 255, 255, 0.92), rgba(241, 246, 245, 0.88));
              border: 1px solid var(--line);
            }

            .stat strong {
              display: block;
              font-size: 2rem;
              font-family: "Space Grotesk", "Avenir Next", sans-serif;
            }

            .stat span {
              color: var(--muted);
            }

            .section-header {
              display: flex;
              justify-content: space-between;
              align-items: end;
              gap: 12px;
              margin-bottom: 18px;
            }

            .section h2 {
              margin: 0;
              font-size: 1.7rem;
            }

            .search {
              width: min(360px, 100%);
              border-radius: 999px;
              border: 1px solid var(--line);
              background: rgba(255, 255, 255, 0.88);
              padding: 12px 16px;
              font: inherit;
            }

            .auth-grid,
            .tag-section {
              display: grid;
              gap: 16px;
            }

            .auth-grid {
              grid-template-columns: repeat(3, minmax(0, 1fr));
            }

            .callout {
              padding: 18px;
              border-radius: var(--radius-md);
              background: rgba(255, 255, 255, 0.82);
              border: 1px solid var(--line);
            }

            .callout strong {
              display: block;
              margin-bottom: 6px;
              color: var(--brand);
            }

            .tag-section + .tag-section {
              margin-top: 26px;
              padding-top: 26px;
              border-top: 1px solid var(--line);
            }

            .tag-title {
              display: flex;
              align-items: center;
              gap: 10px;
            }

            .tag-count {
              padding: 5px 10px;
              border-radius: 999px;
              background: var(--brand-soft);
              color: var(--brand);
              font-size: 0.84rem;
              font-weight: 700;
            }

            .endpoint-card {
              padding: 22px;
              border-radius: var(--radius-md);
              background: rgba(255, 255, 255, 0.88);
              border: 1px solid var(--line);
              display: grid;
              gap: 16px;
            }

            .endpoint-top {
              display: flex;
              flex-wrap: wrap;
              gap: 12px;
              align-items: center;
            }

            .method {
              padding: 7px 12px;
              border-radius: 999px;
              color: white;
              font-weight: 700;
              letter-spacing: 0.06em;
              text-transform: uppercase;
              font-size: 0.78rem;
            }

            .method-get { background: var(--get); }
            .method-post { background: var(--post); }
            .method-put { background: var(--put); }
            .method-patch { background: var(--patch); }
            .method-delete { background: var(--delete); }

            .path {
              font-size: 1.02rem;
              color: var(--text);
              overflow-wrap: anywhere;
            }

            .endpoint-card h3 {
              margin: 0;
              font-size: 1.25rem;
            }

            .meta-row {
              display: flex;
              flex-wrap: wrap;
              gap: 10px;
            }

            .meta-pill {
              padding: 8px 10px;
              border-radius: 999px;
              background: rgba(217, 237, 235, 0.62);
              border: 1px solid rgba(11, 93, 99, 0.12);
              font-size: 0.88rem;
              color: var(--brand);
            }

            .meta-pill code {
              font-size: 0.82rem;
            }

            .detail-grid {
              display: grid;
              gap: 14px;
            }

            table {
              width: 100%;
              border-collapse: collapse;
              border-spacing: 0;
              overflow: hidden;
              border-radius: var(--radius-sm);
              border: 1px solid var(--line);
            }

            th,
            td {
              text-align: left;
              vertical-align: top;
              padding: 12px;
              border-bottom: 1px solid var(--line);
            }

            th {
              background: rgba(11, 93, 99, 0.08);
              color: var(--brand);
              font-size: 0.82rem;
              text-transform: uppercase;
              letter-spacing: 0.06em;
            }

            tr:last-child td {
              border-bottom: none;
            }

            .example-block,
            .schema-card pre {
              margin: 0;
              padding: 16px;
              border-radius: var(--radius-sm);
              background: #101a1f;
              color: #eff6f7;
              overflow: auto;
              font-size: 0.86rem;
              line-height: 1.55;
            }

            .schema-list {
              display: grid;
              gap: 12px;
            }

            .schema-card {
              border: 1px solid var(--line);
              border-radius: var(--radius-md);
              background: rgba(255, 255, 255, 0.88);
              overflow: hidden;
            }

            .schema-card summary {
              cursor: pointer;
              list-style: none;
              display: flex;
              justify-content: space-between;
              align-items: center;
              gap: 12px;
              padding: 16px 18px;
            }

            .schema-card summary::-webkit-details-marker {
              display: none;
            }

            .schema-type {
              color: var(--muted);
              font-size: 0.9rem;
            }

            .footer-note {
              margin-top: 18px;
              color: var(--muted);
              font-size: 0.92rem;
            }

            @media (max-width: 1120px) {
              .layout {
                grid-template-columns: 1fr;
              }

              .sidebar {
                position: static;
              }

              .hero-grid,
              .auth-grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }
            }

            @media (max-width: 720px) {
              .page {
                width: min(100%, calc(100% - 20px));
                padding-top: 12px;
              }

              .hero,
              .section,
              .sidebar {
                padding: 20px;
              }

              .hero-grid,
              .auth-grid {
                grid-template-columns: 1fr;
              }

              .section-header {
                align-items: stretch;
                flex-direction: column;
              }
            }
          </style>
        </head>
        <body>
          <div class="page">
            <div class="layout">
              <aside class="panel sidebar">
                <span class="kicker">Nexum API v#{escape_html(info.fetch("version", "1.0.0"))}</span>
                <h1>#{escape_html(info.fetch("title", "API Reference"))}</h1>
                <p class="lede">#{htmlize_text(info.fetch("summary", "Prospect-ready API overview generated from the OpenAPI contract."))}</p>
                <div class="meta-stack">
                  <div class="meta-chip">
                    <strong>Generated</strong>
                    #{escape_html(generated_at)}
                  </div>
                  <div class="meta-chip">
                    <strong>Source Contract</strong>
                    <code>docs/openapi/v1.yaml</code>
                  </div>
                </div>
                <div class="sidebar-links">
                  <a href="openapi/v1.yaml">Download OpenAPI YAML</a>
                  <a href="api_reference.md">Open Markdown Reference</a>
                  <a href="#schemas">Browse Schemas</a>
                </div>
                <h2 style="margin: 24px 0 10px; font-size: 1rem; color: var(--brand);">Tags</h2>
                <nav class="tag-nav">
                  #{render_tag_navigation(grouped_endpoints)}
                </nav>
              </aside>

              <main class="content">
                <section class="panel hero">
                  <span class="kicker">Prospect-facing reference</span>
                  <h2>Integration teams can review the surface area in one place.</h2>
                  <p class="lede">#{htmlize_text(info.fetch("description", "Contract-first reference for API v1 endpoints. Monetary and rate fields are represented as strings. Error responses are deterministic and machine-readable."))}</p>
                  <div class="hero-grid">
                    <div class="stat">
                      <strong>#{endpoints.size}</strong>
                      <span>Total endpoints</span>
                    </div>
                    <div class="stat">
                      <strong>#{endpoints.count { |entry| %w[POST PUT PATCH DELETE].include?(entry[:method]) }}</strong>
                      <span>Mutating operations</span>
                    </div>
                    <div class="stat">
                      <strong>#{grouped_endpoints.keys.size}</strong>
                      <span>Functional domains</span>
                    </div>
                    <div class="stat">
                      <strong>#{schemas.keys.size}</strong>
                      <span>Named schemas</span>
                    </div>
                  </div>
                </section>

                <section class="panel section" id="authentication">
                  <div class="section-header">
                    <div>
                      <h2>Authentication</h2>
                      <p class="meta-note">The contract separates health probes from token-backed business operations.</p>
                    </div>
                  </div>
                  <div class="auth-grid">
                    <div class="callout">
                      <strong>Bearer token</strong>
                      Partner business endpoints under <code>/api/v1</code> expect a Bearer token unless the operation is the OAuth token issue flow.
                    </div>
                    <div class="callout">
                      <strong>Client credentials</strong>
                      <code>/api/v1/oauth/token/{tenant_slug}</code> issues access tokens and supports client credentials exchange.
                    </div>
                    <div class="callout">
                      <strong>Idempotency required</strong>
                      Every mutating operation includes the <code>Idempotency-Key</code> header in the OpenAPI contract.
                    </div>
                  </div>
                </section>

                <section class="panel section" id="endpoints">
                  <div class="section-header">
                    <div>
                      <h2>Endpoints</h2>
                      <p class="meta-note">Filter by path, tag, method, or operation id.</p>
                    </div>
                    <input class="search" id="endpoint-search" type="search" placeholder="Search endpoints">
                  </div>
                  #{render_endpoint_sections(grouped_endpoints)}
                </section>

                <section class="panel section" id="schemas">
                  <div class="section-header">
                    <div>
                      <h2>Schemas</h2>
                      <p class="meta-note">Named component schemas from the contract, rendered as expandable JSON.</p>
                    </div>
                  </div>
                  <div class="schema-list">
                    #{render_schema_sections(schemas)}
                  </div>
                  <p class="footer-note">Generated from <code>docs/openapi/v1.yaml</code>. Re-run <code>cd app && rv ruby run -- script/generate_documentation.rb</code> whenever the contract changes.</p>
                </section>
              </main>
            </div>
          </div>

          <script>
            (function() {
              const searchInput = document.getElementById("endpoint-search");
              const cards = Array.from(document.querySelectorAll("[data-endpoint-search]"));
              const sections = Array.from(document.querySelectorAll("[data-tag-section]"));

              function applyFilter() {
                const query = searchInput.value.trim().toLowerCase();

                cards.forEach(function(card) {
                  const haystack = card.getAttribute("data-endpoint-search");
                  const visible = query === "" || haystack.indexOf(query) !== -1;
                  card.hidden = !visible;
                });

                sections.forEach(function(section) {
                  const visibleCards = section.querySelectorAll(".endpoint-card:not([hidden])");
                  section.hidden = visibleCards.length === 0;
                });
              }

              searchInput.addEventListener("input", applyFilter);
            })();
          </script>
        </body>
      </html>
    HTML
  end

  def render_tag_navigation(grouped_endpoints)
    grouped_endpoints.keys.sort.map do |tag|
      <<~HTML.chomp
        <a href="##{slugify(tag)}">#{escape_html(tag)} <span class="meta-note">(#{grouped_endpoints.fetch(tag).size})</span></a>
      HTML
    end.join("\n")
  end

  def render_endpoint_sections(grouped_endpoints)
    grouped_endpoints.keys.sort.map do |tag|
      entries = grouped_endpoints.fetch(tag)

      <<~HTML
        <section class="tag-section" id="#{slugify(tag)}" data-tag-section>
          <div class="tag-title">
            <h3 style="margin: 0; font-size: 1.4rem;">#{escape_html(tag)}</h3>
            <span class="tag-count">#{entries.size} endpoints</span>
          </div>
          #{entries.map { |entry| render_endpoint_card(entry) }.join("\n")}
        </section>
      HTML
    end.join("\n")
  end

  def render_endpoint_card(entry)
    <<~HTML
      <article class="endpoint-card" id="#{entry[:anchor_id]}" data-endpoint-search="#{escape_html(entry[:search_text])}">
        <div class="endpoint-top">
          <span class="method method-#{entry[:method].downcase}">#{escape_html(entry[:method])}</span>
          <code class="path">#{escape_html(entry[:path])}</code>
        </div>
        <div>
          <h3>#{escape_html(entry[:summary])}</h3>
          #{entry[:description].present? ? %(<p class="meta-note" style="margin-top: 8px;">#{htmlize_text(entry[:description])}</p>) : ""}
        </div>
        <div class="meta-row">
          <span class="meta-pill">Auth: #{escape_html(entry[:authentication])}</span>
          <span class="meta-pill">Idempotency: #{entry[:idempotency_required] ? "Required" : "Not required"}</span>
          <span class="meta-pill">Operation ID: <code>#{escape_html(entry[:operation_id])}</code></span>
        </div>
        <div class="detail-grid">
          #{render_parameters_table(entry[:parameters])}
          #{render_request_bodies_table(entry[:request_bodies])}
          #{render_request_examples(entry[:request_examples])}
          #{render_responses_table(entry[:responses])}
        </div>
      </article>
    HTML
  end

  def render_parameters_table(parameters)
    return "" if parameters.empty?

    rows = parameters.map do |parameter|
      <<~HTML.chomp
        <tr>
          <td><code>#{escape_html(parameter[:name])}</code></td>
          <td>#{escape_html(parameter[:location])}</td>
          <td>#{escape_html(parameter[:required])}</td>
          <td><code>#{escape_html(parameter[:schema])}</code></td>
          <td>#{htmlize_text(parameter[:description])}</td>
        </tr>
      HTML
    end.join("\n")

    <<~HTML
      <div>
        <strong style="display: block; margin-bottom: 8px;">Parameters</strong>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>In</th>
              <th>Required</th>
              <th>Schema</th>
              <th>Description</th>
            </tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      </div>
    HTML
  end

  def render_request_bodies_table(request_bodies)
    return "" if request_bodies.empty?

    rows = request_bodies.map do |request_body|
      <<~HTML.chomp
        <tr>
          <td><code>#{escape_html(request_body[:content_type])}</code></td>
          <td>#{escape_html(request_body[:required])}</td>
          <td><code>#{escape_html(request_body[:schema])}</code></td>
        </tr>
      HTML
    end.join("\n")

    <<~HTML
      <div>
        <strong style="display: block; margin-bottom: 8px;">Request body</strong>
        <table>
          <thead>
            <tr>
              <th>Content-Type</th>
              <th>Required</th>
              <th>Schema</th>
            </tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      </div>
    HTML
  end

  def render_request_examples(request_examples)
    return "" if request_examples.empty?

    request_examples.map do |example|
      <<~HTML
        <div>
          <strong style="display: block; margin-bottom: 8px;">Example request (#{escape_html(example[:content_type])})</strong>
          <pre class="example-block"><code>#{escape_html(example[:body])}</code></pre>
        </div>
      HTML
    end.join("\n")
  end

  def render_responses_table(responses)
    return "" if responses.empty?

    rows = responses.map do |response|
      formats = if response[:content].empty?
        "-"
      else
        response[:content].map do |content|
          "#{escape_html(content[:content_type])} <code>#{escape_html(content[:schema])}</code>"
        end.join("<br>")
      end

      <<~HTML.chomp
        <tr>
          <td><code>#{escape_html(response[:status])}</code></td>
          <td>#{htmlize_text(response[:description])}</td>
          <td>#{formats}</td>
        </tr>
      HTML
    end.join("\n")

    <<~HTML
      <div>
        <strong style="display: block; margin-bottom: 8px;">Responses</strong>
        <table>
          <thead>
            <tr>
              <th>Status</th>
              <th>Description</th>
              <th>Content</th>
            </tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      </div>
    HTML
  end

  def render_schema_sections(schemas)
    schemas.keys.sort.map do |schema_name|
      schema = schemas.fetch(schema_name)

      <<~HTML
        <details class="schema-card">
          <summary>
            <span>#{escape_html(schema_name)}</span>
            <span class="schema-type">#{escape_html(schema_label(schema))}</span>
          </summary>
          <pre><code>#{escape_html(JSON.pretty_generate(schema))}</code></pre>
        </details>
      HTML
    end.join("\n")
  end

  def resolve_reference(spec, value)
    return {} if value.nil?
    return value unless value.is_a?(Hash) && value["$ref"].present?

    value["$ref"].delete_prefix("#/").split("/").reduce(spec) do |memo, key|
      memo.fetch(key)
    end
  rescue KeyError
    value
  end

  def schema_label(schema)
    resolved = schema.is_a?(Hash) ? schema : {}

    return resolved["$ref"].split("/").last if resolved["$ref"].present?

    if resolved["type"] == "array"
      "array<#{schema_label(resolved["items"])}>"
    elsif resolved["type"].present?
      resolved["type"]
    elsif resolved["properties"].present?
      "object"
    else
      "inline"
    end
  end

  def example_from_schema(spec, schema)
    resolved = schema.is_a?(Hash) ? schema : {}

    examples = resolved["examples"]
    return examples.first if examples.is_a?(Array) && examples.any?

    return resolved["example"] if resolved.key?("example")
    return resolved["enum"].first if resolved["enum"].is_a?(Array) && resolved["enum"].any?

    case resolved["type"]
    when "object"
      properties = resolved.fetch("properties", {})
      return nil if properties.empty?

      properties.each_with_object({}) do |(name, property_schema), memo|
        example = example_from_schema(spec, resolve_reference(spec, property_schema))
        memo[name] = example unless example.nil?
      end
    when "array"
      item_example = example_from_schema(spec, resolve_reference(spec, resolved["items"]))
      item_example.nil? ? nil : [ item_example ]
    when "string"
      resolved["format"] == "date-time" ? "2026-03-06T10:12:02-03:00" : "string"
    when "integer"
      1
    when "number"
      1.0
    when "boolean"
      true
    else
      nil
    end
  end

  def slugify(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
  end

  def escape_html(value)
    CGI.escapeHTML(value.to_s)
  end

  def htmlize_text(value)
    escape_html(value).gsub("\n", "<br>")
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
