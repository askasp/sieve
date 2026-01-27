# sieve

A library for Phoenix that gives you supabase/firebase-style CRUD without leaving Elixir.

## What it does

You define your Ecto schemas, add some policies (like Postgres RLS but in Elixir), and sieve exposes them all through a single REST endpoint. It handles filtering, sorting, pagination, authorization, and generates an OpenAPI spec automatically.

Instead of writing controller actions for every table, you declare what's exposed and how it's protected. Sieve does the rest.

## Quick example

### 1. Define your resources

```elixir
defmodule MyApp.Resources do
  use Sieve.Resources, repo: MyApp.Repo

  resource "posts", %{
    schema: MyApp.Blog.Post,
    policy: MyApp.Policies.OwnedByUser,
    on_create: [
      %Sieve.JobSpec{worker: MyApp.Workers.NotifyFollowers}
    ]
  }

  resource "comments", %{
    schema: MyApp.Blog.Comment,
    policy: MyApp.Policies.OwnedByUser
  }

  resource "categories", %{
    schema: MyApp.Blog.Category,
    policy: MyApp.Policies.PublicRead
  }
end
```

### 2. Write a policy

Policies control who can do what. They're just modules that return scoped queries.

```elixir
defmodule MyApp.Policies.OwnedByUser do
  use Sieve.Policy

  # Users can only list their own records
  def for_list(queryable, actor, _params, _spec) do
    from(r in queryable, where: r.user_id == ^actor.id)
  end

  # Users can only get their own records
  def for_get(queryable, actor, id, _params, _spec) do
    from(r in queryable, where: r.user_id == ^actor.id and r.id == ^id)
  end

  # Auto-set user_id on create
  def for_create(_schema, actor, attrs, _params, _spec) do
    {:ok, Map.put(attrs, "user_id", actor.id)}
  end

  # Users can only update their own records
  def for_update(queryable, actor, id, attrs, _params, _spec) do
    query = from(r in queryable, where: r.user_id == ^actor.id and r.id == ^id)
    {:ok, %{query: query, attrs: attrs}}
  end

  # Users can only delete their own records
  def for_delete(queryable, actor, id, _params, _spec) do
    query = from(r in queryable, where: r.user_id == ^actor.id and r.id == ^id)
    {:ok, query}
  end
end
```

```elixir
defmodule MyApp.Policies.PublicRead do
  use Sieve.Policy

  # Anyone can list
  def for_list(queryable, _actor, _params, _spec), do: queryable

  # Anyone can get by id
  def for_get(queryable, _actor, id, _params, _spec) do
    from(r in queryable, where: r.id == ^id)
  end

  # Writes denied by default (inherited from Sieve.Policy)
end
```

### 3. Mount the plug

```elixir
# router.ex
scope "/api" do
  pipe_through [:api, :require_auth]

  forward "/", Sieve.Plug,
    resources: MyApp.Resources,
    repo: MyApp.Repo,
    actor_assign: :current_user
end
```

That's it. You now have:

```
GET    /api/posts           # list (filtered by policy)
POST   /api/posts           # create
GET    /api/posts/:id       # get
PATCH  /api/posts/:id       # update
DELETE /api/posts/:id       # delete
```

Same for comments, categories, and anything else you add.

## Query parameters

```bash
# Filter
GET /api/posts?filter[status]=published
GET /api/posts?filter[title]=ilike:hello%
GET /api/posts?filter[views]=gt:100

# Sort
GET /api/posts?order=inserted_at.desc

# Paginate
GET /api/posts?limit=20&offset=40

# Select fields
GET /api/posts?select=id,title,status
```

Filter operators: `like:`, `ilike:`, `gt:`, `gte:`, `lt:`, `lte:`, `ne:`, `in:`, `is_nil:`

## Async workers

Trigger background jobs on CRUD events using Oban:

```elixir
resource "posts", %{
  schema: MyApp.Blog.Post,
  policy: MyApp.Policies.OwnedByUser,
  on_create: [
    %Sieve.JobSpec{worker: MyApp.Workers.IndexPost}
  ],
  on_update: [
    %Sieve.JobSpec{
      worker: MyApp.Workers.NotifySubscribers,
      # Only run when status changes to published
      args: fn before, after_record ->
        if before.status != :published and after_record.status == :published do
          %{post_id: after_record.id}
        end
      end
    }
  ],
  on_delete: [
    %Sieve.JobSpec{worker: MyApp.Workers.CleanupPost}
  ]
}
```

## OpenAPI spec

Generate OpenAPI 3.0 docs from your resource definitions:

```elixir
defmodule MyAppWeb.ApiSpec do
  alias OpenApiSpex.{Info, OpenApi, Server}

  def spec do
    %OpenApi{
      info: %Info{title: "My API", version: "1.0"},
      servers: [%Server{url: "https://api.example.com"}],
      paths: MyApp.Resources.open_api_fragment().paths,
      components: %{schemas: MyApp.Resources.open_api_fragment().schemas}
    }
  end
end
```

## Installation

```elixir
def deps do
  [{:sieve, "~> 0.1.0"}]
end
```

## Why

Writing CRUD controllers is tedious. You end up with the same patterns over and over: authorize, validate, query, respond. Sieve consolidates this into a declarative config.

The constraint is intentional. You give up some flexibility in exchange for consistency and less code. If you need custom logic, write a regular controller for that endpoint.
