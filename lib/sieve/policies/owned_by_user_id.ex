defmodule Sieve.Policies.OwnedByUserId do
  @moduledoc """
  A policy that scopes records by `user_id` field matching `actor.id`.

  Use this for resources where each record belongs to a user and users should
  only be able to access their own records.

  ## Requirements

  - The schema must have a `user_id` field
  - The actor must have an `id` field

  ## Example

      resource "posts", %{
        schema: MyApp.Blog.Post,
        policy: Sieve.Policies.OwnedByUserId
      }

  ## Behavior

  - **List**: Only returns records where `user_id == actor.id`
  - **Get**: Only returns record if `user_id == actor.id`
  - **Create**: Automatically sets `user_id` to `actor.id`
  - **Update**: Only allows update if `user_id == actor.id`
  - **Delete**: Only allows delete if `user_id == actor.id`
  """

  use Sieve.Policy

  def for_list(queryable, actor, _params, _spec) do
    from(q in queryable, where: q.user_id == ^actor.id)
  end

  def for_get(queryable, actor, _id, _params, _spec) do
    from(q in queryable, where: q.user_id == ^actor.id)
  end

  def for_create(_schema, actor, attrs, _params, _spec) do
    {:ok, Map.put(attrs, :user_id, actor.id)}
  end

  def for_update(queryable, actor, _id, attrs, _params, _spec) do
    query = from(q in queryable, where: q.user_id == ^actor.id)
    {:ok, %{query: query, attrs: attrs}}
  end

  def for_delete(queryable, actor, _id, _params, _spec) do
    query = from(q in queryable, where: q.user_id == ^actor.id)
    {:ok, query}
  end
end
