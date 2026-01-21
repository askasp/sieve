# Sieve

A PostgREST-like library for Phoenix and Ecto that provides automatic REST API endpoints with row-level security.

## Features

- **Automatic REST API** - Define tables, get REST endpoints automatically
- **Row-level security** - All queries scoped to the current user via ownership field
- **Field projection** - Control which fields are readable and writable
- **Query capabilities** - Filtering, sorting, pagination, field selection via URL params
- **Multiple registry patterns** - Inline or module-based table definitions (great for codegen)

## Installation

Add `sieve` to your `mix.exs`:

```elixir
def deps do
  [
    {:sieve, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Define your table registry

You have two options for defining tables:

#### Option A: Inline registry (simple, all in one file)

```elixir
defmodule MyApp.TableRegistry do
  use Sieve.Registry

  tables do
    table "profiles", %{
      schema: MyApp.Accounts.Profile,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :display_name, :bio, :inserted_at, :updated_at],
      writable: [:display_name, :bio]
    }

    table "todos", %{
      schema: MyApp.Tasks.Todo,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :title, :done, :inserted_at, :updated_at],
      writable: [:title, :done]
    }
  end
end
```

#### Option B: Module-based registry (recommended for codegen)

This approach lets you define each table in its own file, making it easier to:
- Generate table definitions programmatically
- Edit tables in a visual editor
- Keep code organized with many tables

```elixir
# lib/my_app/tables/profiles.ex
defmodule MyApp.Tables.Profiles do
  @behaviour Sieve.TableSpec

  def spec do
    %{
      schema: MyApp.Accounts.Profile,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :display_name, :bio, :inserted_at, :updated_at],
      writable: [:display_name, :bio]
    }
  end

  def name, do: "profiles"
end

# lib/my_app/tables/todos.ex
defmodule MyApp.Tables.Todos do
  @behaviour Sieve.TableSpec

  def spec do
    %{
      schema: MyApp.Tasks.Todo,
      pk: :id,
      owner_key: :user_id,
      readable: [:id, :title, :done, :inserted_at, :updated_at],
      writable: [:title, :done]
    }
  end

  def name, do: "todos"
end

# lib/my_app/table_registry.ex
defmodule MyApp.TableRegistry do
  use Sieve.Registry

  register_modules([
    MyApp.Tables.Profiles,
    MyApp.Tables.Todos
  ])
end
```

### 2. Create a controller

```elixir
defmodule MyAppWeb.TableController do
  use MyAppWeb, :controller

  use Sieve.Controller,
    registry: MyApp.TableRegistry,
    repo: MyApp.Repo,
    actor_key: :current_user

  action_fallback MyAppWeb.FallbackController
end
```

### 3. Add routes

```elixir
# lib/my_app_web/router.ex
scope "/api", MyAppWeb do
  pipe_through [:api, :auth]  # :auth pipeline must assign current_user

  get  "/:table",     TableController, :index
  get  "/:table/:id", TableController, :show
  patch "/:table/:id", TableController, :update
end
```

### 4. Ensure your schemas have changesets

```elixir
defmodule MyApp.Accounts.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "profiles" do
    field :display_name, :string
    field :bio, :string
    field :user_id, :id

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:display_name, :bio])
    |> validate_required([:display_name])
  end
end
```

## API Usage

Once set up, you get automatic REST endpoints:

### List rows
```bash
GET /api/profiles
GET /api/profiles?select=id,display_name
GET /api/profiles?order=display_name.asc,inserted_at.desc
GET /api/profiles?limit=10&offset=20
```

### Get single row
```bash
GET /api/profiles/123
```

### Update row
```bash
PATCH /api/profiles/123
Content-Type: application/json

{"display_name": "New Name", "bio": "Updated bio"}
```

## Security Model

Sieve enforces row-level security automatically:

1. **Ownership scoping** - All queries filter by `owner_key == current_user.id`
2. **Read protection** - Only fields in `readable` list can be returned
3. **Write protection** - Only fields in `writable` list can be updated
4. **Implicit 404s** - Attempting to access another user's row returns not found

## Table Specification

Each table requires these fields:

- **schema** - The Ecto schema module
- **pk** - Primary key field (usually `:id`)
- **owner_key** - Field that identifies row ownership (e.g., `:user_id`)
- **readable** - List of fields that can be read via the API
- **writable** - List of fields that can be updated via the API

## Query Parameters

### `select` - Field projection
```
GET /api/profiles?select=id,display_name,bio
```
Returns only the specified fields (must be in `readable` list).

### `order` - Sorting
```
GET /api/profiles?order=display_name.asc
GET /api/profiles?order=display_name.desc,inserted_at.asc
```
Sort by one or more fields. Direction is `asc` (default) or `desc`.

### `limit` and `offset` - Pagination
```
GET /api/profiles?limit=10&offset=20
```
Default limit is 50, maximum is 200.

### `filter` - Field filtering
```
GET /api/profiles?filter[status]=active
GET /api/profiles?filter[name]=ilike:john%
GET /api/profiles?filter[age]=gt:18
GET /api/profiles?filter[role]=in:admin,moderator
```

Filter records by field values. Supports operators:

| Operator | Example | SQL Equivalent |
|----------|---------|----------------|
| (none) | `filter[status]=active` | `WHERE status = 'active'` |
| `like:` | `filter[name]=like:John%` | `WHERE name LIKE 'John%'` |
| `ilike:` | `filter[name]=ilike:john%` | `WHERE name ILIKE 'john%'` (case-insensitive) |
| `gt:` | `filter[age]=gt:18` | `WHERE age > 18` |
| `gte:` | `filter[age]=gte:18` | `WHERE age >= 18` |
| `lt:` | `filter[age]=lt:65` | `WHERE age < 65` |
| `lte:` | `filter[age]=lte:65` | `WHERE age <= 65` |
| `ne:` | `filter[status]=ne:deleted` | `WHERE status != 'deleted'` |
| `in:` | `filter[role]=in:a,b,c` | `WHERE role IN ('a', 'b', 'c')` |
| `is_nil:` | `filter[deleted_at]=is_nil:true` | `WHERE deleted_at IS NULL` |
| `is_nil:` | `filter[deleted_at]=is_nil:false` | `WHERE deleted_at IS NOT NULL` |

Multiple filters are combined with AND:
```
GET /api/profiles?filter[status]=active&filter[role]=admin
# WHERE status = 'active' AND role = 'admin'
```

**Security**: Only fields that exist on the schema can be filtered. Optionally, you can restrict filterable fields by adding a `filterable` list to your resource spec:

```elixir
resource "profiles", %{
  schema: MyApp.Profile,
  policy: MyPolicy,
  filterable: [:status, :role, :name]  # Only these fields can be filtered
}
```

## Advanced Usage

### Custom actor resolution

By default, the actor is `conn.assigns.current_user`. You can customize this:

```elixir
use Sieve.Controller,
  registry: MyApp.TableRegistry,
  repo: MyApp.Repo,
  actor_key: :current_account  # Use conn.assigns.current_account instead
```

### Override controller actions

All controller actions are overridable:

```elixir
defmodule MyAppWeb.TableController do
  use MyAppWeb, :controller
  use Sieve.Controller, registry: MyApp.TableRegistry, repo: MyApp.Repo

  # Add custom logging
  def index(conn, params) do
    Logger.info("Table list request: #{inspect(params)}")
    super(conn, params)
  end
end
```

## Architecture

The library is structured in layers:

```
Sieve.Controller     # Phoenix controller (integrates with your app)
       ↓
Sieve.Registry      # Table lookup
       ↓
Sieve.Gateway       # Query building & execution
       ↓
Ecto.Repo          # Database access
```

- **Controller** - Phoenix integration, receives HTTP requests
- **Registry** - Maps table names to specifications
- **Gateway** - Builds secure Ecto queries with filtering, ordering, pagination
- **TableSpec** - Behaviour defining table structure and permissions

## Examples

See the `examples/` directory for:
- `inline_registry.ex` - Simple inline table definitions
- `module_registry.ex` - Module-based registry with separate table files
- `controller.ex` - Phoenix controller setup

## Roadmap

Potential future features:
- [ ] POST support for creating rows
- [ ] DELETE support
- [x] Filtering via URL params (e.g., `?filter[title]=like:hello%`)
- [ ] Relationship embedding/expansion
- [ ] RPC-style function calls
- [ ] Bulk operations

## Credits

Inspired by PostgREST.

