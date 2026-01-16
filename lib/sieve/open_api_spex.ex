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
    Schema
  }

  def fragment(resources_map, opts \\ []) when is_map(resources_map) do
    mount = Keyword.get(opts, :mount, "/api/db")

    Enum.reduce(resources_map, %{paths: %{}, schemas: %{}}, fn {table, spec}, acc ->
      schema_mod = Map.fetch!(spec, :schema)
      pk = Map.get(spec, :pk, :id)

      schema_name = schema_name(table)

      acc
      |> put_schema(schema_name, schema_from_ecto(schema_mod))
      |> put_path("#{mount}/#{table}", path_item_for_collection(table, schema_name))
      |> put_path("#{mount}/#{table}/{id}", path_item_for_member(table, pk, schema_name))
    end)
  end

  def merge_fragment(%OpenApi{} = spec, %{paths: paths, schemas: schemas}) do
    merged_paths = deep_merge(Map.get(spec, :paths, %{}), paths)

    merged_components =
      case spec.components do
        %Components{} = c ->
          %Components{c | schemas: deep_merge(c.schemas || %{}, schemas)}

        nil ->
          %Components{schemas: schemas}
      end

    %OpenApi{spec | paths: merged_paths, components: merged_components}
  end

  defp put_path(acc, path, %PathItem{} = item), do: put_in(acc, [:paths, path], item)

  defp put_schema(acc, name, %Schema{} = schema),
    do: update_in(acc, [:schemas], fn m -> Map.put_new(m, name, schema) end)

  defp path_item_for_collection(table, schema_name) do
    %PathItem{
      get: %Operation{
        operationId: "sieve_list_#{table}",
        summary: "List #{table}",
        parameters: [
          query_param(:order, :string, "order=field.asc,other.desc"),
          query_param(:limit, :integer, "limit"),
          query_param(:offset, :integer, "offset")
        ],
        responses: %{200 => ok_array_response(ref(schema_name))}
      },
      post: %Operation{
        operationId: "sieve_create_#{table}",
        summary: "Create #{table}",
        requestBody: %RequestBody{
          required: true,
          content: %{"application/json" => %MediaType{schema: %Schema{type: :object}}}
        },
        responses: %{201 => ok_object_response(ref(schema_name))}
      }
    }
  end

  defp path_item_for_member(table, _pk, schema_name) do
    %PathItem{
      get: %Operation{
        operationId: "sieve_get_#{table}",
        summary: "Get #{table} by id",
        parameters: [path_param(:id, :integer, "id")],
        responses: %{200 => ok_object_response(ref(schema_name)), 404 => not_found()}
      },
      patch: %Operation{
        operationId: "sieve_update_#{table}",
        summary: "Update #{table} by id",
        parameters: [path_param(:id, :integer, "id")],
        requestBody: %RequestBody{
          required: true,
          content: %{"application/json" => %MediaType{schema: %Schema{type: :object}}}
        },
        responses: %{200 => ok_object_response(ref(schema_name)), 404 => not_found()}
      }
    }
  end

  defp query_param(name, type, desc) do
    %Parameter{
      name: name,
      in: :query,
      description: desc,
      required: false,
      schema: type
    }
  end

  defp path_param(name, type, desc) do
    %Parameter{
      name: name,
      in: :path,
      description: desc,
      required: true,
      schema: type
    }
  end

  defp schema_from_ecto(schema_mod) do
    props =
      schema_mod.__schema__(:fields)
      |> Enum.reduce(%{}, fn field, acc ->
        type = schema_mod.__schema__(:type, field)
        Map.put(acc, Atom.to_string(field), %Schema{type: openapi_type(type)})
      end)

    %Schema{type: :object, properties: props}
  end

  defp openapi_type(:id), do: :integer
  defp openapi_type(:integer), do: :integer
  defp openapi_type(:float), do: :number
  defp openapi_type(:decimal), do: :number
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

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}

  defp schema_name(table), do: Macro.camelize(table)

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end
end
