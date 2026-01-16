defmodule Sieve.Engine do
  @moduledoc false

  import Ecto.Query
  alias Sieve.JobSpec

  @default_limit 50
  @max_limit 200

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

    with {:ok, attrs} <- spec.policy.for_create(spec.schema, actor, attrs, params, spec) do
      changeset = spec.schema.changeset(struct(spec.schema), attrs)

      case repo.insert(changeset) do
        {:ok, record} ->
          # For create: before is nil, after is the created record
          enqueue_jobs(jobs, nil, record)
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
    needs_before = JobSpec.needs_before_after?(jobs)

    with {:ok, %{query: q, attrs: attrs}} <-
           spec.policy.for_update(spec.schema, actor, id, attrs, params, spec),
         q = apply_pk_filter(q, id, spec),
         struct when not is_nil(struct) <- repo.one(q) do
      # Capture before state if any jobs need it
      before_record = if needs_before, do: deep_copy(struct), else: nil

      changeset = spec.schema.changeset(struct, attrs)

      case repo.update(changeset) do
        {:ok, after_record} ->
          enqueue_jobs(jobs, before_record, after_record)
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

    with {:ok, q} <- spec.policy.for_delete(spec.schema, actor, id, params, spec),
         q = apply_pk_filter(q, id, spec),
         struct when not is_nil(struct) <- repo.one(q) do
      case repo.delete(struct) do
        {:ok, deleted} ->
          # For delete: before is the deleted record, after is nil
          enqueue_jobs(jobs, deleted, nil)
          {:ok, deleted}

        {:error, cs} ->
          {:error, {:changeset, cs}}
      end
    else
      nil -> {:error, :not_found}
      {:error, e} -> {:error, e}
    end
  end

  # Job enqueueing

  defp enqueue_jobs([], _before, _after), do: :ok

  defp enqueue_jobs(jobs, before_record, after_record) do
    Enum.each(jobs, fn job_spec ->
      if JobSpec.should_run?(job_spec, before_record, after_record) do
        args = JobSpec.build_args(job_spec, before_record, after_record)
        enqueue_job(job_spec.worker, args, job_spec.opts)
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

  # Query helpers

  defp apply_common(q, params, spec) do
    q
    |> maybe_apply_pk_filter(params, spec)
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
    case Integer.parse(v) do
      {i, _} -> i
      :error -> -1
    end
  end

  defp cast_id(_), do: -1
end
