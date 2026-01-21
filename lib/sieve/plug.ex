defmodule Sieve.Plug do
  @moduledoc """
  Plug for Phoenix router `forward`.

  Example:

      scope "/api", MyAppWeb do
        pipe_through [:api, :auth]
        forward "/db", Sieve.Plug,
          resources: MyApp.ApiResources,
          repo: MyApp.Repo,
          actor_assign: :current_user
      end

  Routes (under the forward mount):
  - GET    /:table        -> list
  - POST   /:table        -> create
  - GET    /:table/:id    -> get
  - PATCH  /:table/:id    -> update
  - PUT    /:table/:id    -> update (alias for PATCH)
  - DELETE /:table/:id    -> delete
  """

  import Plug.Conn

  def init(opts) do
    %{
      resources: Keyword.fetch!(opts, :resources),
      repo: Keyword.fetch!(opts, :repo),
      actor_assign: Keyword.get(opts, :actor_assign, :current_user)
    }
  end

  def call(conn, %{resources: resources, repo: repo, actor_assign: actor_assign} = _opts) do
    actor = conn.assigns[actor_assign]
    params = conn.query_params
    headers = conn.req_headers

    case {conn.method, conn.path_info} do
      {"GET", [table]} ->
        with {:ok, spec} <- fetch(resources, table, headers),
             {:ok, rows} <- Sieve.Engine.list(repo, spec, actor, params) do
          json(conn, 200, rows)
        else
          _ -> send_resp(conn, 404, "")
        end

      {"POST", [table]} ->
        attrs = read_json_body_map!(conn)

        with {:ok, spec} <- fetch(resources, table, headers),
             {:ok, row} <- Sieve.Engine.create(repo, spec, actor, attrs, params) do
          json(conn, 201, row)
        else
          {:error, :unauthorized} -> json(conn, 401, %{error: "Unauthorized"})
          {:error, :forbidden} -> json(conn, 403, %{error: "Forbidden"})
          {:error, {:changeset, cs}} -> json(conn, 422, changeset_errors(cs))
          _ -> send_resp(conn, 400, "")
        end

      {"GET", [table, id]} ->
        with {:ok, spec} <- fetch(resources, table, headers),
             {:ok, row} <- Sieve.Engine.get(repo, spec, actor, id, params) do
          json(conn, 200, row)
        else
          {:error, :not_found} -> send_resp(conn, 404, "")
          _ -> send_resp(conn, 404, "")
        end

      {method, [table, id]} when method in ["PATCH", "PUT"] ->
        attrs = read_json_body_map!(conn)

        with {:ok, spec} <- fetch(resources, table, headers),
             {:ok, row} <- Sieve.Engine.update(repo, spec, actor, id, attrs, params) do
          json(conn, 200, row)
        else
          {:error, :not_found} -> send_resp(conn, 404, "")
          {:error, :unauthorized} -> json(conn, 401, %{error: "Unauthorized"})
          {:error, :forbidden} -> json(conn, 403, %{error: "Forbidden"})
          {:error, {:changeset, cs}} -> json(conn, 422, changeset_errors(cs))
          _ -> send_resp(conn, 400, "")
        end

      {"DELETE", [table, id]} ->
        with {:ok, spec} <- fetch(resources, table, headers),
             {:ok, _deleted} <- Sieve.Engine.delete(repo, spec, actor, id, params) do
          send_resp(conn, 204, "")
        else
          {:error, :not_found} -> send_resp(conn, 404, "")
          {:error, :unauthorized} -> json(conn, 401, %{error: "Unauthorized"})
          {:error, :forbidden} -> json(conn, 403, %{error: "Forbidden"})
          _ -> send_resp(conn, 400, "")
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp fetch(resources, table, headers) do
    case resources.fetch(table) do
      {:ok, spec} -> {:ok, normalize_spec!(spec) |> Map.put(:headers, headers)}
      :error -> {:error, :not_found}
    end
  end

  defp normalize_spec!(spec) do
    for k <- [:schema, :policy, :pk] do
      if Map.get(spec, k) == nil do
        raise ArgumentError, "Sieve resource spec missing #{inspect(k)}: #{inspect(spec)}"
      end
    end

    spec
  end

  defp json(conn, status, data) do
    body = Jason.encode!(jsonable(data))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # --------------------
  # JSON normalization
  # --------------------

  # Lists
  defp jsonable(list) when is_list(list),
    do: Enum.map(list, &jsonable/1)

  # Date / time scalars FIRST (must come before struct/map clauses)
  defp jsonable(%DateTime{} = dt),
    do: DateTime.to_iso8601(dt)

  defp jsonable(%NaiveDateTime{} = ndt),
    do: NaiveDateTime.to_iso8601(ndt)

  defp jsonable(%Date{} = d),
    do: Date.to_iso8601(d)

  defp jsonable(%Time{} = t),
    do: Time.to_iso8601(t)

  # Decimal - keep as string to preserve precision
  defp jsonable(%Decimal{} = dec),
    do: Decimal.to_string(dec)

  # Tuples → arrays
  defp jsonable(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&jsonable/1)

  # Ecto schema structs (drop __meta__ and unloaded assocs)
  defp jsonable(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Enum.into(%{}, fn {k, v} -> {k, jsonable(v)} end)
  end

  # Plain maps
  defp jsonable(%{} = map),
    do: Enum.into(map, %{}, fn {k, v} -> {k, jsonable(v)} end)

  # Everything else
  defp jsonable(other), do: other

  # --------------------
  # Request helpers
  # --------------------

  defp read_json_body_map!(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        if body == "", do: %{}, else: Jason.decode!(body)

      %{} = m ->
        m
    end
  end

  defp changeset_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end
end
