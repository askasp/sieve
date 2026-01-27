defmodule Sieve.Engine do
  @moduledoc false

  import Ecto.Query
  alias Sieve.JobSpec
  alias Sieve.Broadcast

  @default_limit Application.compile_env(:sieve, :default_limit, 50)
  @max_limit Application.compile_env(:sieve, :max_limit, 200)

  @spec list(module(), map(), term(), map()) :: {:ok, list()} | {:error, term()}
  def list(repo, spec, actor, params) do
    q =
      spec.policy.for_list(spec.schema, actor, params, spec)
      |> apply_common(params, spec)

    {:ok, repo.all(q)}
  end

  @spec get(module(), map(), term(), term(), map()) :: {:ok, map() | struct()} | {:error, term()}
  def get(repo, spec, actor, id, params) do
    id = cast_id(id)

    q =
      spec.policy.for_get(spec.schema, actor, id, params, spec)
      |> apply_common(params, spec)

    case repo.one(q) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @spec create(module(), map(), term(), map(), map()) :: {:ok, map() | struct()} | {:error, term()}
  def create(repo, spec, actor, attrs, params) do
    jobs = Map.get(spec, :on_create, [])
    pk = Map.get(spec, :pk, :id)

    with {:ok, attrs} <- spec.policy.for_create(spec.schema, actor, attrs, params, spec) do
      changeset = apply_changeset(spec.schema, struct(spec.schema), attrs, actor)

      case repo.insert(changeset) do
        {:ok, record} ->
          # For create: before is nil, after is the created record
          enqueue_jobs(jobs, nil, record)
          maybe_broadcast(:created, spec, pk, nil, record)
          {:ok, record}

        {:error, cs} ->
          {:error, {:changeset, cs}}
      end
    end
  end

  @spec update(module(), map(), term(), term(), map(), map()) ::
          {:ok, map() | struct()} | {:error, term()}
  def update(repo, spec, actor, id, attrs, params) do
    id = cast_id(id)
    jobs = Map.get(spec, :on_update, [])
    pk = Map.get(spec, :pk, :id)
    needs_before = JobSpec.needs_before_after?(jobs) or Broadcast.broadcast_configured?(spec)

    with {:ok, %{query: q, attrs: attrs}} <-
           spec.policy.for_update(spec.schema, actor, id, attrs, params, spec),
         q = apply_pk_filter(q, id, spec),
         struct when not is_nil(struct) <- repo.one(q) do
      # Capture before state if any jobs need it or broadcast is configured
      before_record = if needs_before, do: deep_copy(struct), else: nil

      changeset = apply_changeset(spec.schema, struct, attrs, actor)

      case repo.update(changeset) do
        {:ok, after_record} ->
          enqueue_jobs(jobs, before_record, after_record)
          maybe_broadcast(:updated, spec, pk, before_record, after_record)
          {:ok, after_record}

        {:error, cs} ->
          {:error, {:changeset, cs}}
      end
    else
      nil -> {:error, :not_found}
      {:error, e} -> {:error, e}
    end
  end

  @spec delete(module(), map(), term(), term(), map()) ::
          {:ok, struct()} | {:error, term()}
  def delete(repo, spec, actor, id, params) do
    id = cast_id(id)
    jobs = Map.get(spec, :on_delete, [])
    pk = Map.get(spec, :pk, :id)

    with {:ok, q} <- spec.policy.for_delete(spec.schema, actor, id, params, spec),
         q = apply_pk_filter(q, id, spec),
         struct when not is_nil(struct) <- repo.one(q) do
      case repo.delete(struct) do
        {:ok, deleted} ->
          # For delete: before is the deleted record, after is nil
          enqueue_jobs(jobs, deleted, nil)
          maybe_broadcast(:deleted, spec, pk, deleted, nil)
          {:ok, deleted}

        {:error, cs} ->
          {:error, {:changeset, cs}}
      end
    else
      nil -> {:error, :not_found}
      {:error, e} -> {:error, e}
    end
  end

  # Broadcasting

  defp maybe_broadcast(event, spec, pk, before_record, after_record) do
    if Broadcast.broadcast_configured?(spec) do
      # Get the PK value from the appropriate record
      record = after_record || before_record
      pk_value = Map.get(record, pk)
      Broadcast.broadcast(event, spec.name, pk_value, before_record, after_record, spec.broadcast)
    end
  end

  # Job enqueueing

  defp enqueue_jobs([], _before, _after), do: :ok

  defp enqueue_jobs(jobs, before_record, after_record) do
    Enum.each(jobs, fn job_spec ->
      if JobSpec.should_run?(job_spec, before_record, after_record) do
        args = JobSpec.build_args(job_spec, before_record, after_record)

        # Skip if args is nil (indicates job should not be enqueued)
        if args != nil do
          enqueue_job(job_spec.worker, args, job_spec.opts)
        end
      end
    end)
  end

  defp enqueue_job(worker, args, opts) do
    # Check if Oban is available at runtime (it's provided by the user's app, not Sieve)
    if Code.ensure_loaded?(Oban) do
      # Sanitize args to be JSON-safe (convert structs to maps, etc.)
      safe_args = jsonable(args)
      job = apply(worker, :new, [safe_args, opts])
      # Use apply to avoid compile-time warning since Oban is optional
      apply(Oban, :insert, [job])
    else
      require Logger
      Logger.warning("Sieve: Job configured but Oban not available. Worker: #{inspect(worker)}")
    end
  end

  # JSON normalization for job args

  defp jsonable(list) when is_list(list),
    do: Enum.map(list, &jsonable/1)

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp jsonable(%Date{} = d), do: Date.to_iso8601(d)
  defp jsonable(%Time{} = t), do: Time.to_iso8601(t)
  defp jsonable(%Decimal{} = dec), do: Decimal.to_string(dec)

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

  defp jsonable(%{} = map),
    do: Enum.into(map, %{}, fn {k, v} -> {k, jsonable(v)} end)

  defp jsonable(other), do: other

  # Deep copy a struct to preserve before state (Ecto structs are mutable through associations)
  defp deep_copy(struct) do
    struct
    |> Map.from_struct()
    |> then(&struct(struct.__struct__, &1))
  end

  # Changeset helper - tries changeset/3 with actor first, falls back to changeset/2

  defp apply_changeset(schema, struct, attrs, actor) do
    if function_exported?(schema, :changeset, 3) do
      schema.changeset(struct, attrs, actor)
    else
      schema.changeset(struct, attrs)
    end
  end

  # Query helpers

  defp apply_common(q, params, spec) do
    q
    |> maybe_apply_pk_filter(params, spec)
    |> maybe_filter(params, spec)
    |> maybe_order(params)
    |> maybe_limit_offset(params)
  end

  defp apply_pk_filter(q, id, spec) do
    pk = Map.get(spec, :pk, :id)
    where(q, [r], field(r, ^pk) == ^id)
  end

  # Optional: allow get to be implemented as list-scope + pk filter by passing "id" param.
  # If policy already includes pk condition, this will be a no-op for list routes.
  defp maybe_apply_pk_filter(q, %{"id" => id}, spec) do
    pk = Map.get(spec, :pk, :id)
    id = cast_id(id)
    where(q, [r], field(r, ^pk) == ^id)
  end

  defp maybe_apply_pk_filter(q, _params, _spec), do: q

  # Filter support: ?filter[field]=value or ?filter[field]=op:value
  # Supported operators: like, gt, lt, gte, lte, ne, in, is_nil
  # Examples:
  #   ?filter[status]=active           -> WHERE status = 'active'
  #   ?filter[name]=like:foo%          -> WHERE name LIKE 'foo%'
  #   ?filter[age]=gt:18               -> WHERE age > 18
  #   ?filter[role]=in:admin,user      -> WHERE role IN ('admin', 'user')
  #   ?filter[deleted_at]=is_nil:true  -> WHERE deleted_at IS NULL
  defp maybe_filter(q, %{"filter" => filters}, spec) when is_map(filters) do
    schema = spec.schema
    schema_fields = schema.__schema__(:fields) |> MapSet.new()

    # Check for filterable whitelist in spec
    filterable = Map.get(spec, :filterable)

    Enum.reduce(filters, q, fn {field_name, value}, acc ->
      field = safe_to_atom(field_name)

      cond do
        # Skip if field doesn't exist on schema
        field == nil or not MapSet.member?(schema_fields, field) ->
          acc

        # Skip if filterable list exists and field is not in it
        filterable != nil and field not in filterable ->
          acc

        true ->
          apply_filter(acc, field, value)
      end
    end)
  end

  defp maybe_filter(q, _params, _spec), do: q

  # Parse operator prefix and apply appropriate filter
  defp apply_filter(q, field, "like:" <> pattern) do
    where(q, [r], like(field(r, ^field), ^pattern))
  end

  defp apply_filter(q, field, "ilike:" <> pattern) do
    where(q, [r], ilike(field(r, ^field), ^pattern))
  end

  defp apply_filter(q, field, "gt:" <> value) do
    where(q, [r], field(r, ^field) > ^cast_filter_value(value))
  end

  defp apply_filter(q, field, "gte:" <> value) do
    where(q, [r], field(r, ^field) >= ^cast_filter_value(value))
  end

  defp apply_filter(q, field, "lt:" <> value) do
    where(q, [r], field(r, ^field) < ^cast_filter_value(value))
  end

  defp apply_filter(q, field, "lte:" <> value) do
    where(q, [r], field(r, ^field) <= ^cast_filter_value(value))
  end

  defp apply_filter(q, field, "ne:" <> value) do
    where(q, [r], field(r, ^field) != ^cast_filter_value(value))
  end

  defp apply_filter(q, field, "in:" <> values) do
    list =
      values
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&cast_filter_value/1)

    where(q, [r], field(r, ^field) in ^list)
  end

  defp apply_filter(q, field, "not_in:" <> values) do
    list =
      values
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&cast_filter_value/1)

    where(q, [r], field(r, ^field) not in ^list)
  end

  defp apply_filter(q, field, "is_nil:" <> flag) do
    case flag do
      f when f in ["true", "1", "yes"] ->
        where(q, [r], is_nil(field(r, ^field)))

      _ ->
        where(q, [r], not is_nil(field(r, ^field)))
    end
  end

  # Default: exact match
  defp apply_filter(q, field, value) do
    where(q, [r], field(r, ^field) == ^value)
  end

  # Cast filter values for numeric comparisons
  defp cast_filter_value(value) do
    cond do
      # Integer
      Regex.match?(~r/^-?\d+$/, value) ->
        String.to_integer(value)

      # Float/Decimal
      Regex.match?(~r/^-?\d+\.\d+$/, value) ->
        String.to_float(value)

      # Keep as string
      true ->
        value
    end
  end

  # Safely convert string to existing atom to prevent atom table exhaustion
  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  # Minimal order: order=field.asc,other.desc (no validation here; policies can enforce by scoping/selecting)
  defp maybe_order(q, %{"order" => order}) when is_binary(order) do
    clauses =
      order
      |> String.split(",", trim: true)
      |> Enum.map(fn part ->
        case String.split(part, ".", parts: 2) do
          [field, dir] -> {String.to_atom(field), dir}
          [field] -> {String.to_atom(field), "asc"}
        end
      end)
      |> Enum.map(fn {f, dir} ->
        dir =
          case dir do
            "desc" -> :desc
            "asc" -> :asc
            _ -> :asc
          end

        {dir, f}
      end)

    Enum.reduce(clauses, q, fn {dir, field}, acc ->
      order_by(acc, [r], [{^dir, field(r, ^field)}])
    end)
  rescue
    _ -> q
  end

  defp maybe_order(q, _), do: q

  defp maybe_limit_offset(q, params) do
    limit = parse_int(Map.get(params, "limit"), @default_limit) |> min(@max_limit)
    offset = parse_int(Map.get(params, "offset"), 0) |> max(0)
    q |> limit(^limit) |> offset(^offset)
  end

  defp parse_int(nil, d), do: d

  defp parse_int(v, _d) when is_integer(v), do: v

  defp parse_int(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> d
    end
  end

  defp cast_id(v) when is_integer(v), do: v

  defp cast_id(v) when is_binary(v) do
    # Check if it looks like a UUID (contains hyphens or is 32+ hex chars)
    if String.contains?(v, "-") or (String.length(v) >= 32 and String.match?(v, ~r/^[a-fA-F0-9]+$/)) do
      # Keep as string for UUID/binary_id types
      v
    else
      # Try to parse as integer for regular integer IDs
      case Integer.parse(v) do
        {i, ""} -> i
        _ -> v
      end
    end
  end

  defp cast_id(_), do: -1
end
