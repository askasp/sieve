defmodule Sieve.Resources do
  @moduledoc """
  Macro to define resources (exposed tables) in one place.

  ## Example

      defmodule MyApp.ApiResources do
        use Sieve.Resources, repo: MyApp.Repo

        resource "todos", %{
          schema: MyApp.Tasks.Todo,
          pk: :id,
          policy: Sieve.Policies.OwnedByUserId
        }

        # With background jobs
        resource "posts", %{
          schema: MyApp.Blog.Post,
          pk: :id,
          policy: Sieve.Policies.OwnedByUserId,
          on_create: [
            %Sieve.JobSpec{worker: MyApp.IndexWorker}
          ],
          on_update: [
            %Sieve.JobSpec{
              worker: MyApp.ReindexWorker,
              when: fn before, record -> before.title != record.title end
            }
          ],
          on_delete: [
            %Sieve.JobSpec{worker: MyApp.CleanupWorker}
          ]
        }
      end

  ## Job Specs

  Jobs are defined using `Sieve.JobSpec` structs with the following fields:

  - `worker` - The Oban worker module (required)
  - `args` - Function `(before, after) -> map()` or static map for job args
  - `opts` - Oban job options (queue, priority, etc.)
  - `when` - Function `(before, after) -> boolean()` to conditionally run

  ### Before/After Values

  - `:create` - before is `nil`, after is the created record
  - `:update` - before is record before update, after is record after
  - `:delete` - before is record before deletion, after is `nil`

  ### Performance Optimization

  If no jobs have a `when` clause or dynamic `args` function, Sieve skips fetching
  before/after records entirely. This means simple "always run" jobs have zero overhead.

  ## Generated Functions

  - `fetch/1` => {:ok, spec} | :error
  - `fetch!/1` => spec | raises KeyError
  - `all/0` => map of name => spec
  - `open_api_fragment/0` => %{paths: map, schemas: map}

  ## Programmatic CRUD Helpers

  When you pass `repo: MyApp.Repo` to `use Sieve.Resources`, helper functions are
  generated for each resource that trigger on_create/on_update/on_delete jobs:

      # Generated for resource "lab_visits":
      create_lab_visits(attrs, actor)
      update_lab_visits(id, attrs, actor)
      delete_lab_visits(id, actor)
      get_lab_visits(id, actor, params \\\\ %{})
      list_lab_visits(actor, params \\\\ %{})

  ### Convenience Actors

      # System actor for backend operations (bypasses user-scoped checks)
      system_actor()  # => %{role: :system}

  ### Example Usage

      # In a backend function (not an API call)
      defmodule MyApp.SomeContext do
        alias MyApp.ApiResources

        def complete_order(order_id) do
          # This triggers on_update jobs just like an API call would!
          ApiResources.update_orders(order_id, %{status: :completed}, ApiResources.system_actor())
        end
      end
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      import Sieve.Resources, only: [resource: 2]
      Module.register_attribute(__MODULE__, :sieve_resources, accumulate: true)
      Module.put_attribute(__MODULE__, :sieve_repo, Keyword.get(opts, :repo))
      @before_compile Sieve.Resources
    end
  end

  defmacro resource(name, opts) when is_binary(name) do
    # Store the AST of opts, not the evaluated value
    quote do
      @sieve_resources {unquote(name), unquote(Macro.escape(opts))}
    end
  end

  defmacro __before_compile__(env) do
    resources = Module.get_attribute(env.module, :sieve_resources)
    repo = Module.get_attribute(env.module, :sieve_repo)

    # Build a list of {name, opts_ast} tuples that we'll turn into map entries
    resource_entries =
      for {name, opts_ast} <- resources do
        quote do
          {unquote(name),
           unquote(opts_ast)
           |> Map.new()
           |> Map.put(:name, unquote(name))
           |> Sieve.Resources.normalize_job_specs()}
        end
      end

    # Generate CRUD helper functions for each resource (only if repo is configured)
    crud_helpers =
      if repo do
        for {name, _opts_ast} <- resources do
          # Convert "lab_visits" to :create_lab_visits, :update_lab_visits, etc.
          create_fn = String.to_atom("create_#{name}")
          update_fn = String.to_atom("update_#{name}")
          delete_fn = String.to_atom("delete_#{name}")
          get_fn = String.to_atom("get_#{name}")
          list_fn = String.to_atom("list_#{name}")

          quote do
            @doc "Create a #{unquote(name)} record. Triggers on_create jobs."
            def unquote(create_fn)(attrs, actor) do
              Sieve.Engine.create(unquote(repo), fetch!(unquote(name)), actor, attrs, %{})
            end

            @doc "Update a #{unquote(name)} record by id. Triggers on_update jobs."
            def unquote(update_fn)(id, attrs, actor) do
              Sieve.Engine.update(unquote(repo), fetch!(unquote(name)), actor, id, attrs, %{})
            end

            @doc "Delete a #{unquote(name)} record by id. Triggers on_delete jobs."
            def unquote(delete_fn)(id, actor) do
              Sieve.Engine.delete(unquote(repo), fetch!(unquote(name)), actor, id, %{})
            end

            @doc "Get a #{unquote(name)} record by id."
            def unquote(get_fn)(id, actor, params \\ %{}) do
              Sieve.Engine.get(unquote(repo), fetch!(unquote(name)), actor, id, params)
            end

            @doc "List #{unquote(name)} records."
            def unquote(list_fn)(actor, params \\ %{}) do
              Sieve.Engine.list(unquote(repo), fetch!(unquote(name)), actor, params)
            end
          end
        end
      else
        []
      end

    quote do
      def all do
        Map.new(unquote(resource_entries))
      end

      def fetch(name) when is_binary(name) do
        case Map.fetch(all(), name) do
          {:ok, spec} -> {:ok, spec}
          :error -> :error
        end
      end

      def fetch!(name) when is_binary(name) do
        case fetch(name) do
          {:ok, spec} -> spec
          :error -> raise KeyError, key: name
        end
      end

      def open_api_fragment do
        Sieve.OpenApiSpex.fragment(all())
      end

      @doc "System actor for backend operations. Use when mutating from non-API code."
      def system_actor, do: %{role: :system}

      @doc "Admin actor with a specific user id."
      def admin_actor(user_id), do: %{auth_user_id: user_id, role: :admin}

      @doc "User actor with a specific user id."
      def user_actor(user_id), do: %{auth_user_id: user_id, role: :user}

      unquote_splicing(crud_helpers)
    end
  end

  @doc false
  def normalize_job_specs(spec) do
    spec
    |> Map.put_new(:on_create, [])
    |> Map.put_new(:on_update, [])
    |> Map.put_new(:on_delete, [])
  end
end
