defmodule Sieve do
  @moduledoc """
  Policy-based authorization for Phoenix and Ecto REST APIs.

  Sieve provides a simple, clean way to add row-level security to your Phoenix app
  using policies similar to Postgres RLS or Supabase.

  ## Quick Start

  ### 1. Create your schema (using mix phx.gen.schema)

      mix phx.gen.schema Blog.Post posts title:string body:text user_id:integer

  ### 2. Create a policy

      defmodule MyApp.Blog.PostPolicy do
        use Sieve.Policy,
          schema: MyApp.Blog.Post,
          name: "posts",
          owner_key: :user_id

        # That's it! Default implementations are auto-generated.
        # Override callbacks only if you need custom logic.
      end

  ### 3. Register your policies

      defmodule MyApp.PolicyRegistry do
        use Sieve.Registry,
          policies: [
            MyApp.Blog.PostPolicy,
            MyApp.Accounts.ProfilePolicy
          ]
      end

  ### 4. Forward to Sieve.Router

      # In your Phoenix router
      scope "/api", MyAppWeb do
        pipe_through [:api, :auth]  # :auth must set current_user

        forward "/", Sieve.Router,
          registry: MyApp.PolicyRegistry,
          repo: MyApp.Repo,
          actor_key: :current_user
      end

  ## API Usage

      # List posts
      GET /api/posts?select=id,title&order=title.asc&limit=10

      # Get single post
      GET /api/posts/123

      # Update post
      PATCH /api/posts/123
      {"title": "New Title"}

  ## Using policies outside controllers

      # In a LiveView
      alias Sieve.Repo, as: SieveRepo

      def mount(_params, _session, socket) do
        case SieveRepo.list(MyApp.Repo, PostPolicy, socket.assigns.current_user) do
          {:ok, posts} -> {:ok, assign(socket, posts: posts)}
          {:error, _} -> {:ok, socket}
        end
      end

  ## Modules

  - `Sieve.Policy` - Define authorization policies
  - `Sieve.Registry` - Register policies for lookup
  - `Sieve.Router` - Plug router (just forward to it!)
  - `Sieve.Repo` - Data access layer (reusable in LiveViews, etc.)
  """
end
