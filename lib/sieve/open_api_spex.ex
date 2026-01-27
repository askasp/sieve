defmodule Sieve.OpenApiSpex do
  @moduledoc false

  alias OpenApiSpex.{
    Components,
    MediaType,
    OpenApi,
    Operation,
    Parameter,
    PathItem,
    Reference,
    RequestBody,
    Response,
    Schema,
    SecurityScheme
  }

  @bearer_security [%{"BearerAuth" => []}]

  def fragment(resources_map, opts \\ []) when is_map(resources_map) do
    mount = Keyword.get(opts, :mount, "/api/db")
    tag = Keyword.get(opts, :tag)
    singularize = Keyword.get(opts, :singularize, false)

    Enum.reduce(resources_map, %{paths: %{}, schemas: %{}}, fn {table, spec}, acc ->
      # Skip resources marked as hidden from OpenAPI spec
      if Map.get(spec, :hidden, false) do
        acc
      else
        schema_mod = Map.fetch!(spec, :schema)
        pk = Map.get(spec, :pk, :id)

        # Allow overriding the schema name via :schema_name option, or singularize if enabled
        schema_name = Map.get(spec, :schema_name) || derive_schema_name(table, singularize)

        input_schema_name = "#{schema_name}Input"

        # Get required fields: first check spec override, then schema's required_fields/0 function
        schema_required = extract_required_fields(schema_mod)
        input_required = Map.get(spec, :required) || schema_required
        # Response required: use spec override, or fall back to schema's required_fields
        response_required = Map.get(spec, :response_required) || schema_required

        acc
        |> put_schema(schema_name, schema_from_ecto(schema_mod, :response, response_required))
        |> put_schema(input_schema_name, schema_from_ecto(schema_mod, :input, input_required))
        |> put_path("#{mount}/#{table}", path_item_for_collection(table, schema_name, input_schema_name, tag, spec))
        |> put_path("#{mount}/#{table}/{id}", path_item_for_member(table, pk, schema_name, input_schema_name, tag))
      end
    end)
  end

  def merge_fragment(%OpenApi{} = spec, %{paths: paths, schemas: schemas}) do
    merged_paths = deep_merge(Map.get(spec, :paths, %{}), paths)

    bearer_scheme = %SecurityScheme{
      type: "http",
      scheme: "bearer",
      bearerFormat: "JWT"
    }

    merged_components =
      case spec.components do
        %Components{} = c ->
          %Components{
            c |
            schemas: deep_merge(c.schemas || %{}, schemas),
            securitySchemes: Map.merge(c.securitySchemes || %{}, %{"BearerAuth" => bearer_scheme})
          }

        nil ->
          %Components{schemas: schemas, securitySchemes: %{"BearerAuth" => bearer_scheme}}
      end

    %OpenApi{spec | paths: merged_paths, components: merged_components}
  end

  defp put_path(acc, path, %PathItem{} = item), do: put_in(acc, [:paths, path], item)

  defp put_schema(acc, name, %Schema{} = schema),
    do: update_in(acc, [:schemas], fn m -> Map.put_new(m, name, schema) end)

  defp path_item_for_collection(table, schema_name, input_schema_name, tag, spec) do
    tags = if tag, do: [tag], else: []
    filter_params = build_filter_params(spec)

    %PathItem{
      get: %Operation{
        tags: tags,
        operationId: "list_#{table}",
        summary: "List #{table}",
        security: @bearer_security,
        parameters: [
          query_param(:order, :string, "order=field.asc,other.desc"),
          query_param(:limit, :integer, "limit"),
          query_param(:offset, :integer, "offset")
        ] ++ filter_params,
        responses: %{200 => ok_array_response(ref(schema_name)), 401 => unauthorized()}
      },
      post: %Operation{
        tags: tags,
        operationId: "create_#{table}",
        summary: "Create #{table}",
        security: @bearer_security,
        requestBody: %RequestBody{
          required: true,
          content: %{"application/json" => %MediaType{schema: ref(input_schema_name)}}
        },
        responses: %{201 => ok_object_response(ref(schema_name)), 401 => unauthorized()}
      }
    }
  end

  defp path_item_for_member(table, _pk, schema_name, input_schema_name, tag) do
    tags = if tag, do: [tag], else: []

    %PathItem{
      get: %Operation{
        tags: tags,
        operationId: "get_#{table}",
        summary: "Get #{table} by id",
        security: @bearer_security,
        parameters: [path_param(:id, :string, "id (UUID)")],
        responses: %{200 => ok_object_response(ref(schema_name)), 401 => unauthorized(), 404 => not_found()}
      },
      patch: %Operation{
        tags: tags,
        operationId: "update_#{table}",
        summary: "Update #{table} by id",
        security: @bearer_security,
        parameters: [path_param(:id, :string, "id (UUID)")],
        requestBody: %RequestBody{
          required: true,
          content: %{"application/json" => %MediaType{schema: ref(input_schema_name)}}
        },
        responses: %{200 => ok_object_response(ref(schema_name)), 401 => unauthorized(), 404 => not_found()}
      },
      delete: %Operation{
        tags: tags,
        operationId: "delete_#{table}",
        summary: "Delete #{table} by id",
        security: @bearer_security,
        parameters: [path_param(:id, :string, "id (UUID)")],
        responses: %{204 => no_content(), 401 => unauthorized(), 404 => not_found()}
      }
    }
  end

  defp query_param(name, type, desc) do
    %Parameter{
      name: name,
      in: :query,
      description: desc,
      required: false,
      schema: %Schema{type: type}
    }
  end

  defp build_filter_params(spec) do
    case Map.get(spec, :filterable) do
      nil ->
        []

      fields when is_list(fields) ->
        schema_mod = Map.fetch!(spec, :schema)

        Enum.map(fields, fn field ->
          type = schema_mod.__schema__(:type, field)
          openapi_type = filter_param_type(type)

          %Parameter{
            name: "filter[#{field}]",
            in: :query,
            description: "Filter by #{field}. Supports operators: gt:, gte:, lt:, lte:, ne:, like:, ilike:, in:, not_in:, is_nil:",
            required: false,
            schema: %Schema{type: openapi_type}
          }
        end)
    end
  end

  defp filter_param_type(:integer), do: :string
  defp filter_param_type(:float), do: :string
  defp filter_param_type(:decimal), do: :string
  defp filter_param_type(:boolean), do: :string
  defp filter_param_type(:binary_id), do: :string
  defp filter_param_type(_), do: :string

  defp path_param(name, type, desc) do
    %Parameter{
      name: name,
      in: :path,
      description: desc,
      required: true,
      schema: %Schema{type: type}
    }
  end

  @auto_fields ~w(id inserted_at updated_at)a

  defp schema_from_ecto(schema_mod, mode, extra_required) do
    fields = schema_mod.__schema__(:fields)

    fields =
      if mode == :input do
        Enum.reject(fields, &(&1 in @auto_fields))
      else
        fields
      end

    props =
      Enum.reduce(fields, %{}, fn field, acc ->
        type = schema_mod.__schema__(:type, field)
        Map.put(acc, Atom.to_string(field), openapi_schema(type))
      end)

    # For response schemas, auto-fields are always required plus any extra
    # For input schemas, use extra_required from resource spec
    required =
      case mode do
        :response ->
          # id, inserted_at, updated_at are always present in responses
          auto = @auto_fields |> Enum.filter(&(&1 in fields))
          extra = extra_required |> Enum.filter(&(&1 in fields))
          (auto ++ extra) |> Enum.uniq() |> Enum.map(&Atom.to_string/1)

        :input ->
          extra_required
          |> Enum.reject(&(&1 in @auto_fields))
          |> Enum.filter(&(&1 in fields))
          |> Enum.map(&Atom.to_string/1)
      end

    schema = %Schema{type: :object, properties: props}

    if required == [] do
      schema
    else
      %Schema{schema | required: required}
    end
  end

  # Build properties map for an embedded schema (handles nested embeds recursively)
  defp build_embed_properties(embed_mod) do
    fields = embed_mod.__schema__(:fields)

    Enum.reduce(fields, %{}, fn field, acc ->
      type = embed_mod.__schema__(:type, field)
      Map.put(acc, Atom.to_string(field), openapi_schema(type))
    end)
  end

  # Handle Ecto.Enum - newer Ecto versions use nested tuple structure
  defp openapi_schema({:parameterized, {Ecto.Enum, %{mappings: mappings}}}) do
    values = mappings |> Keyword.keys() |> Enum.map(&Atom.to_string/1)
    %Schema{type: :string, enum: values}
  end

  # Handle older Ecto.Enum structure (3-tuple)
  defp openapi_schema({:parameterized, Ecto.Enum, %{mappings: mappings}}) do
    values = mappings |> Keyword.keys() |> Enum.map(&Atom.to_string/1)
    %Schema{type: :string, enum: values}
  end

  # Handle Ecto.Embedded (embeds_one / embeds_many)
  defp openapi_schema({:parameterized, {Ecto.Embedded, %Ecto.Embedded{cardinality: cardinality, related: related_mod}}}) do
    embed_props = build_embed_properties(related_mod)
    embed_object = %Schema{type: :object, properties: embed_props}

    case cardinality do
      :one -> %Schema{embed_object | nullable: true}
      :many -> %Schema{type: :array, items: embed_object}
    end
  end

  defp openapi_schema(type), do: %Schema{type: openapi_type(type)}

  defp openapi_type(:id), do: :integer
  defp openapi_type(:integer), do: :integer
  defp openapi_type(:float), do: :number
  defp openapi_type(:decimal), do: :string
  defp openapi_type(:boolean), do: :boolean
  defp openapi_type(:string), do: :string
  defp openapi_type(:binary_id), do: :string
  defp openapi_type(:utc_datetime), do: :string
  defp openapi_type(:naive_datetime), do: :string
  defp openapi_type({:array, _}), do: :array
  defp openapi_type(_), do: :string

  defp ok_array_response(item_schema) do
    %Response{
      description: "OK",
      content: %{
        "application/json" => %MediaType{
          schema: %Schema{type: :array, items: item_schema}
        }
      }
    }
  end

  defp ok_object_response(schema) do
    %Response{
      description: "OK",
      content: %{"application/json" => %MediaType{schema: schema}}
    }
  end

  defp not_found, do: %Response{description: "Not found"}

  defp no_content, do: %Response{description: "No content"}

  defp unauthorized, do: %Response{description: "Unauthorized"}

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}

  defp derive_schema_name(table, true), do: table |> singularize() |> Macro.camelize()
  defp derive_schema_name(table, false), do: Macro.camelize(table)

  # Simple singularization for common English plural patterns
  defp singularize(word) when is_binary(word) do
    cond do
      String.ends_with?(word, "ies") ->
        String.replace_suffix(word, "ies", "y")

      # Words ending in -sses (e.g., "classes" -> "class")
      String.ends_with?(word, "sses") ->
        String.replace_suffix(word, "ses", "")

      # Words ending in -ses where singular ends in -se (e.g., "responses" -> "response")
      String.ends_with?(word, "nses") or String.ends_with?(word, "rses") ->
        String.replace_suffix(word, "s", "")

      String.ends_with?(word, "ches") or String.ends_with?(word, "shes") or
          String.ends_with?(word, "xes") ->
        String.replace_suffix(word, "es", "")

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

  # Extract required fields from schema module
  # Checks for required_fields/0 function first, then falls back to empty list
  defp extract_required_fields(schema_mod) do
    # Ensure the module is loaded before checking for exported functions
    Code.ensure_loaded(schema_mod)

    if function_exported?(schema_mod, :required_fields, 0) do
      schema_mod.required_fields()
    else
      []
    end
  end
end
