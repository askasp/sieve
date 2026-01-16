defmodule Sieve.Policy do
  @moduledoc """
  Policy callbacks for Sieve resources.

  Policies define authorization rules for CRUD operations. They receive the actor
  (current user), parameters, and return scoped queries or modified attributes.

  ## Approach

  - **List/Get**: Return a scoped query that only includes rows the actor can access.
  - **Update**: Return scoped query + possibly rewritten attrs.
  - **Create**: Return possibly rewritten attrs.
  - **Delete**: Return scoped query for rows the actor can delete.

  ## Default Behavior

  By default, all operations are denied (deny-by-default). Override the callbacks
  you want to allow.

  ## Built-in Policies

  Sieve provides reusable policies for common patterns:

  - `Sieve.Policies.Public` - All operations allowed, no restrictions
  - `Sieve.Policies.OwnedByUserId` - Scopes by `user_id` field matching `actor.id`

  ## Custom Policies

  For custom authorization logic, create your own policy module:

      defmodule MyApp.Policies.AdminOnly do
        use Sieve.Policy

        def for_list(q, actor, _params, _spec) do
          if actor.admin?, do: q, else: from(x in q, where: false)
        end

        def for_get(q, actor, _id, _params, _spec) do
          if actor.admin?, do: q, else: from(x in q, where: false)
        end

        def for_create(_schema, actor, attrs, _params, _spec) do
          if actor.admin?, do: {:ok, attrs}, else: {:error, :forbidden}
        end

        def for_update(q, actor, _id, attrs, _params, _spec) do
          if actor.admin? do
            {:ok, %{query: q, attrs: attrs}}
          else
            {:error, :forbidden}
          end
        end

        def for_delete(q, actor, _id, _params, _spec) do
          if actor.admin?, do: {:ok, q}, else: {:error, :forbidden}
        end
      end
  """

  @type actor :: term()
  @type spec :: map()
  @type params :: map()
  @type attrs :: map()
  @type id :: term()
  @type queryable :: Ecto.Queryable.t()

  @callback for_list(queryable(), actor(), params(), spec()) :: queryable()

  @callback for_get(queryable(), actor(), id(), params(), spec()) :: queryable()

  @callback for_update(queryable(), actor(), id(), attrs(), params(), spec()) ::
              {:ok, %{query: queryable(), attrs: attrs()}} | {:error, term()}

  @callback for_create(schema :: module(), actor(), attrs(), params(), spec()) ::
              {:ok, attrs()} | {:error, term()}

  @callback for_delete(queryable(), actor(), id(), params(), spec()) ::
              {:ok, queryable()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Sieve.Policy
      import Ecto.Query

      # Deny-by-default implementations
      def for_list(queryable, _actor, _params, _spec), do: from(x in queryable, where: false)
      def for_get(queryable, _actor, _id, _params, _spec), do: from(x in queryable, where: false)
      def for_update(_queryable, _actor, _id, _attrs, _params, _spec), do: {:error, :forbidden}
      def for_create(_schema, _actor, _attrs, _params, _spec), do: {:error, :forbidden}
      def for_delete(_queryable, _actor, _id, _params, _spec), do: {:error, :forbidden}

      defoverridable for_list: 4, for_get: 5, for_update: 6, for_create: 5, for_delete: 5
    end
  end
end
