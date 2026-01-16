defmodule Sieve.Resources do
  @moduledoc """
  Macro to define resources (exposed tables) in one place.

  ## Example

      defmodule MyApp.ApiResources do
        use Sieve.Resources

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
  """

  defmacro __using__(_opts) do
    quote do
      import Sieve.Resources, only: [resource: 2]
      Module.register_attribute(__MODULE__, :sieve_resources, accumulate: true)
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
