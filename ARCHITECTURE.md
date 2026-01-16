# Sieve Architecture

A clean, simple library for policy-based authorization in Phoenix.

## Core Modules

The library consists of just 4 core modules:

### 1. `Sieve.Policy` (lib/sieve/policy.ex)
Defines the policy behavior and provides a macro for easy policy creation.

**Responsibilities:**
- Define authorization callbacks (for_list, for_read, for_create, for_update, for_delete)
- Store policy configuration (schema, name, owner_key, readable, writable fields)
- Generate default implementations when owner_key is provided

**Usage:**
```elixir
defmodule MyApp.Blog.PostPolicy do
  use Sieve.Policy,
    schema: MyApp.Blog.Post,
    name: "posts",
    owner_key: :user_id,
    readable: [:id, :title, :body],
    writable: [:title, :body]
end
```

### 2. `Sieve.Registry` (lib/sieve/registry.ex)
Simple registry for looking up policies by table name.

**Responsibilities:**
- Register policy modules
- Provide `fetch/1` function to lookup policies by name

**Usage:**
```elixir
defmodule MyApp.PolicyRegistry do
  use Sieve.Registry,
    policies: [
      MyApp.Blog.PostPolicy,
      MyApp.Accounts.ProfilePolicy
    ]
end
```

### 3. `Sieve.Repo` (lib/sieve/repo.ex)
Data access layer with policy-based authorization.

**Responsibilities:**
- Execute queries with authorization checks
- Handle field projection (select)
- Handle ordering and pagination
- Filter writable fields

**Usage:**
```elixir
# In a controller or LiveView
Sieve.Repo.list(MyApp.Repo, MyApp.Blog.PostPolicy, current_user, params)
Sieve.Repo.get(MyApp.Repo, MyApp.Blog.PostPolicy, current_user, id)
Sieve.Repo.update(MyApp.Repo, MyApp.Blog.PostPolicy, current_user, id, attrs)
```

### 4. `Sieve.Controller` (lib/sieve/controller.ex)
Phoenix controller integration.

**Responsibilities:**
- Provide index, show, update actions
- Lookup policies from registry
- Call Sieve.Repo functions with proper parameters

**Usage:**
```elixir
defmodule MyAppWeb.ApiController do
  use MyAppWeb, :controller
  use Sieve.Controller,
    registry: MyApp.PolicyRegistry,
    repo: MyApp.Repo,
    actor_key: :current_user
end
```

## Data Flow

### For a list request (GET /api/posts)

1. Request hits `ApiController.index/2`
2. Controller looks up `PostPolicy` from registry
3. Controller calls `Sieve.Repo.list(repo, PostPolicy, current_user, params)`
4. Repo calls `PostPolicy.for_list(query, current_user)` to scope the query
5. Repo applies ordering and pagination
6. Repo selects only readable fields
7. Repo returns results

### For a get request (GET /api/posts/123)

1. Request hits `ApiController.show/2`
2. Controller looks up `PostPolicy` from registry
3. Controller calls `Sieve.Repo.get(repo, PostPolicy, current_user, id)`
4. Repo fetches the record
5. Repo calls `PostPolicy.for_read(record, current_user)` to authorize
6. Repo returns only readable fields

### For an update request (PATCH /api/posts/123)

1. Request hits `ApiController.update/2`
2. Controller looks up `PostPolicy` from registry
3. Controller calls `Sieve.Repo.update(repo, PostPolicy, current_user, id, attrs)`
4. Repo filters attrs to only include writable fields
5. Repo fetches the record
6. Repo calls `PostPolicy.for_update(record, attrs, current_user)` to authorize
7. Repo updates the record using the schema's changeset
8. Repo returns only readable fields

## Key Design Decisions

### 1. Policy as the core abstraction
Instead of separate "table specs" and "policies", everything is a policy. The policy contains both the schema configuration and authorization logic.

### 2. Phoenix Controller over Plug
Using Phoenix controllers instead of a custom Plug router keeps things familiar and allows easy customization.

### 3. Sieve.Repo for reusability
By exposing `Sieve.Repo`, policies can be reused outside of controllers (e.g., in LiveViews, background jobs, etc.).

### 4. Simple registry
The registry is just a lookup table. No complex auto-discovery or compilation magic.

### 5. Minimal API surface
- Policy: 5 callbacks
- Registry: 1 function (fetch/1)
- Repo: 3 functions (list/4, get/4, update/5)
- Controller: 3 actions (index, show, update)

## File Structure

```
lib/sieve/
├── policy.ex        # Policy behavior and macro (143 lines)
├── registry.ex      # Policy registry (43 lines)
├── repo.ex          # Data access layer (223 lines)
└── controller.ex    # Phoenix controller (66 lines)
```

Total: ~475 lines of code for the entire library.

## Extending the Library

### Adding delete support
Add to `Sieve.Repo`:
```elixir
def delete(repo, policy, actor, id) do
  config = policy.__policy_config__()
  q = from r in config.schema, where: r.id == ^id

  case repo.one(q) do
    nil -> {:error, :not_found}
    record ->
      case policy.for_delete(record, actor) do
        :ok -> repo.delete(record)
        {:error, reason} -> {:error, reason}
      end
  end
end
```

Add to `Sieve.Controller`:
```elixir
def delete(conn, %{"table" => table, "id" => id}) do
  actor = Map.get(conn.assigns, @actor_key)

  with {:ok, policy} <- @registry.fetch(table),
       {:ok, _} <- SieveRepo.delete(@repo, policy, actor, id) do
    send_resp(conn, 204, "")
  end
end
```

### Adding create support
Similar pattern to update, using `policy.for_create(attrs, actor)`.

### Adding complex queries
Users can implement custom functions in their policies:
```elixir
defmodule PostPolicy do
  use Sieve.Policy, ...

  def list_published(repo, actor) do
    config = __policy_config__()
    q = from p in config.schema, where: p.published == true
    repo.all(q)
  end
end
```
