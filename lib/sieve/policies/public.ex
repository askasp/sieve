defmodule Sieve.Policies.Public do
  @moduledoc """
  A fully permissive policy that allows all operations.

  Use this for resources that should be publicly accessible with no restrictions.

  ## Example

      resource "posts", %{
        schema: MyApp.Blog.Post,
        policy: Sieve.Policies.Public
      }

  ## Warning

  This policy allows anyone to create, read, update, and delete records.
  Only use it for truly public resources.
  """

  use Sieve.Policy

  def for_list(queryable, _actor, _params, _spec), do: queryable

  def for_get(queryable, _actor, _id, _params, _spec), do: queryable

  def for_create(_schema, _actor, attrs, _params, _spec), do: {:ok, attrs}

  def for_update(queryable, _actor, _id, attrs, _params, _spec) do
    {:ok, %{query: queryable, attrs: attrs}}
  end

  def for_delete(queryable, _actor, _id, _params, _spec), do: {:ok, queryable}
end
