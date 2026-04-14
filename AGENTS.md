# Elixir Phoenix Guide — Agent Instructions

## Ecto Conventions

# Ecto Conventions and Best Practices

## Schema Design

### Basic Schema Structure

```elixir
defmodule MyApp.Media.Image do
  use Ecto.Schema
  import Ecto.Changeset

  schema "images" do
    field :title, :string
    field :description, :string
    field :filename, :string
    field :file_path, :string
    field :content_type, :string
    field :file_size, :integer

    belongs_to :folder, MyApp.Media.Folder

    timestamps()
  end

  @doc false
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:title, :description, :filename, :file_path, :content_type, :file_size, :folder_id])
    |> validate_required([:title, :filename, :file_path, :content_type, :file_size])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_number(:file_size, greater_than: 0)
    |> foreign_key_constraint(:folder_id)
  end
end
```

### Field Types

Common field types:
- `:string` - Variable length text (VARCHAR)
- `:text` - Long text (TEXT)
- `:integer` - Whole numbers
- `:float` - Decimal numbers
- `:boolean` - true/false
- `:date` - Date only
- `:time` - Time only
- `:naive_datetime` - DateTime without timezone
- `:utc_datetime` - DateTime with UTC timezone
- `:binary` - Binary data
- `:map` - JSONB in Postgres

### Associations

```elixir
# One-to-many
belongs_to :folder, MyApp.Media.Folder
has_many :images, MyApp.Media.Image

# Many-to-many
many_to_many :tags, MyApp.Media.Tag, join_through: "images_tags"

# Has one
has_one :profile, MyApp.Accounts.Profile
```

## Changesets

### Basic Changeset Pattern

```elixir
def changeset(struct, attrs) do
  struct
  |> cast(attrs, [:field1, :field2])           # Cast allowed fields
  |> validate_required([:field1])              # Required fields
  |> validate_length(:field1, min: 1, max: 255) # Length validation
  |> unique_constraint(:field1)                # Unique constraint
end
```

### Validation Functions

```elixir
# Required fields
|> validate_required([:title, :content])

# Length
|> validate_length(:title, min: 1, max: 255)
|> validate_length(:description, min: 10)

# Format (regex)
|> validate_format(:email, ~r/@/)

# Inclusion in list
|> validate_inclusion(:status, ["active", "inactive"])

# Exclusion from list
|> validate_exclusion(:role, ["banned"])

# Number validation
|> validate_number(:age, greater_than: 0, less_than: 150)
|> validate_number(:price, greater_than_or_equal_to: 0)

# Custom validation
|> validate_change(:field, fn :field, value ->
  if valid?(value), do: [], else: [field: "is invalid"]
end)

# Confirmation (password confirmation)
|> validate_confirmation(:password)

# Acceptance (terms of service)
|> validate_acceptance(:terms)
```

### Constraints

Database constraints checked at insert/update:

```elixir
# Unique constraint
|> unique_constraint(:email)
|> unique_constraint(:name, name: :folders_name_index)

# Foreign key constraint
|> foreign_key_constraint(:folder_id)

# Check constraint
|> check_constraint(:price, name: :price_must_be_positive)

# No assoc constraint (prevent orphans)
|> no_assoc_constraint(:images)
```

### Changeset Actions

```elixir
# For validation without save
changeset = Map.put(changeset, :action, :validate)

# For insert
changeset = Map.put(changeset, :action, :insert)

# For update
changeset = Map.put(changeset, :action, :update)
```

## Queries

### Basic Queries

```elixir
import Ecto.Query

# Get all
Repo.all(Image)

# Get by ID
Repo.get(Image, id)
Repo.get!(Image, id)  # Raises if not found

# Get by field
Repo.get_by(Image, title: "Sunset")

# Get first
Repo.one(query)
```

### Building Queries

```elixir
# Where clause
query = from i in Image, where: i.folder_id == ^folder_id

# Multiple conditions
query = from i in Image,
  where: i.folder_id == ^folder_id,
  where: i.file_size > 1000

# Or conditions
query = from i in Image,
  where: i.folder_id == ^folder_id or is_nil(i.folder_id)

# Order by
query = from i in Image, order_by: [desc: i.inserted_at]

# Limit
query = from i in Image, limit: 10

# Offset
query = from i in Image, offset: 10

# Select specific fields
query = from i in Image, select: {i.id, i.title}

# Select map
query = from i in Image, select: %{id: i.id, title: i.title}
```

### Piping Queries

```elixir
Image
|> where([i], i.folder_id == ^folder_id)
|> order_by([i], desc: i.inserted_at)
|> limit(10)
|> Repo.all()
```

### Joins

```elixir
# Inner join
query = from i in Image,
  join: f in assoc(i, :folder),
  where: f.name == "Vacation"

# Left join
query = from i in Image,
  left_join: f in assoc(i, :folder),
  select: {i, f}

# Preload (avoid N+1)
query = from i in Image, preload: [:folder]
```

### Aggregations

```elixir
# Count
Repo.aggregate(Image, :count)
from(i in Image, select: count(i.id)) |> Repo.one()

# Sum
from(i in Image, select: sum(i.file_size)) |> Repo.one()

# Average
from(i in Image, select: avg(i.file_size)) |> Repo.one()

# Group by
from(i in Image,
  group_by: i.folder_id,
  select: {i.folder_id, count(i.id)}
) |> Repo.all()
```

## Repository Operations

### Insert

```elixir
# With changeset
%Image{}
|> Image.changeset(attrs)
|> Repo.insert()

# Returns {:ok, image} or {:error, changeset}

# Bang version (raises on error)
Repo.insert!(changeset)
```

### Update

```elixir
# With changeset
image
|> Image.changeset(attrs)
|> Repo.update()

# Returns {:ok, image} or {:error, changeset}
```

### Delete

```elixir
# Delete struct
Repo.delete(image)

# Delete all matching query
query = from i in Image, where: i.folder_id == ^folder_id
Repo.delete_all(query)
```

### Upsert

```elixir
%Image{}
|> Image.changeset(attrs)
|> Repo.insert(
  on_conflict: {:replace, [:title, :description]},
  conflict_target: :filename
)
```

## Preloading

### Avoid N+1 Queries

```elixir
# Bad - N+1 queries
images = Repo.all(Image)
Enum.each(images, fn image ->
  IO.puts(image.folder.name)  # Query per image!
end)

# Good - Single query with join
images = Repo.all(from i in Image, preload: [:folder])
Enum.each(images, fn image ->
  IO.puts(image.folder.name)
end)
```

### Multiple Preloads

```elixir
# Preload multiple associations
query = from i in Image, preload: [:folder, :tags]

# Nested preload
query = from f in Folder, preload: [images: :tags]

# Preload with custom query
images_query = from i in Image, where: i.file_size > 1000
query = from f in Folder, preload: [images: ^images_query]
```

## Transactions

```elixir
Repo.transaction(fn ->
  case create_folder(attrs) do
    {:ok, folder} ->
      case create_image(folder, image_attrs) do
        {:ok, image} -> image
        {:error, reason} -> Repo.rollback(reason)
      end
    {:error, reason} ->
      Repo.rollback(reason)
  end
end)

# Returns {:ok, result} or {:error, reason}
```

## Context Pattern

Wrap database operations in context functions:

```elixir
defmodule MyApp.Media do
  alias MyApp.Media.{Image, Folder}
  alias MyApp.Repo
  import Ecto.Query

  # List functions
  def list_images do
    Image
    |> order_by(desc: :inserted_at)
    |> preload(:folder)
    |> Repo.all()
  end

  def list_images_by_folder(folder_id) do
    Image
    |> where([i], i.folder_id == ^folder_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Get functions
  def get_image!(id), do: Repo.get!(Image, id)

  def get_folder!(id), do: Repo.get!(Folder, id)

  # Create functions
  def create_image(attrs \\ %{}) do
    %Image{}
    |> Image.changeset(attrs)
    |> Repo.insert()
  end

  def create_folder(attrs \\ %{}) do
    %Folder{}
    |> Folder.changeset(attrs)
    |> Repo.insert()
  end

  # Update functions
  def update_image(%Image{} = image, attrs) do
    image
    |> Image.changeset(attrs)
    |> Repo.update()
  end

  # Delete functions
  def delete_image(%Image{} = image) do
    Repo.delete(image)
  end

  # Business logic
  def move_image_to_folder(%Image{} = image, folder_id) do
    update_image(image, %{folder_id: folder_id})
  end
end
```

## Migrations

### Creating Migrations

```bash
mix ecto.gen.migration create_images
```

### Migration Structure

```elixir
defmodule MyApp.Repo.Migrations.CreateImages do
  use Ecto.Migration

  def change do
    create table(:images) do
      add :title, :string, null: false
      add :description, :text
      add :filename, :string, null: false
      add :file_path, :string, null: false
      add :content_type, :string, null: false
      add :file_size, :integer, null: false
      add :folder_id, references(:folders, on_delete: :nilify_all)

      timestamps()
    end

    create index(:images, [:folder_id])
    create index(:images, [:inserted_at])
  end
end
```

### Migration Operations

```elixir
# Add column
alter table(:images) do
  add :priority, :integer, default: 0
end

# Remove column
alter table(:images) do
  remove :old_field
end

# Rename column
rename table(:images), :old_name, to: :new_name

# Add index
create index(:images, [:title])
create unique_index(:folders, [:name])

# Remove index
drop index(:images, [:title])

# Add constraint
create constraint(:images, :file_size_must_be_positive, check: "file_size > 0")
```

## Common Patterns

### Soft Delete

```elixir
schema "images" do
  field :deleted_at, :utc_datetime
  # ...
end

def list_images do
  from(i in Image, where: is_nil(i.deleted_at))
  |> Repo.all()
end

def soft_delete(%Image{} = image) do
  update_image(image, %{deleted_at: DateTime.utc_now()})
end
```

### Ordering with Nulls

```elixir
# Nulls last
from i in Image, order_by: [asc_nulls_last: i.folder_id]

# Nulls first
from i in Image, order_by: [desc_nulls_first: i.priority]
```

### Dynamic Filters

```elixir
def list_images(filters) do
  Image
  |> apply_filters(filters)
  |> Repo.all()
end

defp apply_filters(query, filters) do
  Enum.reduce(filters, query, &apply_filter/2)
end

defp apply_filter({:folder_id, id}, query) do
  where(query, [i], i.folder_id == ^id)
end

defp apply_filter({:search, term}, query) do
  where(query, [i], ilike(i.title, ^"%#{term}%"))
end

defp apply_filter(_, query), do: query
```

---

## Condensed Rules for Subagents

### Ecto Rules
1. Always use changesets for inserts/updates — never raw maps
2. Preload associations before accessing them — avoid N+1
3. Use transactions for multi-step operations
4. Add database constraints AND changeset validations
5. Use contexts for database access — never call Repo from web layer
6. Add indexes on foreign keys and frequently queried fields

### Nested Association Rules
1. Use cast_assoc/3 for has_many/has_one — never manually insert children
2. Use Ecto.Multi for operations spanning unrelated tables
3. Set on_delete explicitly — :delete_all for owned children, :nothing for references
4. Always create indexes on foreign key columns
5. Use on_replace: :delete for list management in cast_assoc
6. Preload associations before updating — cast_assoc needs loaded data

### Changeset Rules
1. Create separate named changesets per operation
2. Never require foreign key fields in cast_assoc child changesets
3. Compose changesets with pipes
4. Pair unsafe_validate_unique with unique_constraint
5. Use update_change/3 for field transforms

## LiveView Checklist

# LiveView Development Checklist

Use this checklist when implementing or reviewing LiveView modules.

## Module Setup

- [ ] Use correct LiveView module: `use MyAppWeb, :live_view`
- [ ] Add `@impl true` before all callback functions
- [ ] Import necessary aliases at top of module
- [ ] Define module documentation with `@moduledoc`

```elixir
defmodule MyAppWeb.GalleryLive do
  use MyAppWeb, :live_view

  alias MyApp.Media
  alias MyApp.Media.{Image, Folder}

  @moduledoc """
  LiveView for managing image gallery.
  """
end
```

## Mount Implementation

- [ ] Handle both disconnected and connected states
- [ ] Check `connected?(socket)` for side effects
- [ ] Subscribe to PubSub topics only when connected
- [ ] Initialize all socket assigns
- [ ] Return proper tuple: `{:ok, socket}` or `{:ok, socket, temporary_assigns: [...]}`

```elixir
@impl true
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "images")
  end

  socket =
    socket
    |> assign(:images, Media.list_images())
    |> assign(:folders, Media.list_folders())
    |> assign(:selected_folder, nil)

  {:ok, socket}
end
```

## Handle Params

- [ ] Implement `handle_params/3` if route has parameters
- [ ] Always return `{:noreply, socket}`
- [ ] Load data based on URL params
- [ ] Add `@impl true` attribute

```elixir
@impl true
def handle_params(%{"id" => folder_id}, _uri, socket) do
  folder = Media.get_folder!(folder_id)
  images = Media.list_images_by_folder(folder_id)

  socket =
    socket
    |> assign(:selected_folder, folder)
    |> assign(:images, images)

  {:noreply, socket}
end

@impl true
def handle_params(_params, _uri, socket) do
  {:noreply, assign(socket, :selected_folder, nil)}
end
```

## Handle Event

- [ ] Add `@impl true` attribute
- [ ] Pattern match on event name
- [ ] Extract params using pattern matching
- [ ] Always return `{:noreply, socket}`
- [ ] Handle errors gracefully with flash messages
- [ ] Update relevant socket assigns

```elixir
@impl true
def handle_event("delete_image", %{"id" => id}, socket) do
  image = Media.get_image!(id)

  case Media.delete_image(image) do
    {:ok, _} ->
      socket =
        socket
        |> put_flash(:info, "Image deleted")
        |> update(:images, fn images ->
          Enum.reject(images, &(&1.id == id))
        end)

      {:noreply, socket}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Failed to delete")}
  end
end
```

## Handle Info

- [ ] Add `@impl true` attribute
- [ ] Pattern match on message structure
- [ ] Handle PubSub broadcasts
- [ ] Update socket state based on message
- [ ] Always return `{:noreply, socket}`

```elixir
@impl true
def handle_info({:image_created, image}, socket) do
  {:noreply, update(socket, :images, fn images -> [image | images] end)}
end

@impl true
def handle_info({:image_deleted, image_id}, socket) do
  {:noreply, update(socket, :images, fn images ->
    Enum.reject(images, &(&1.id == image_id))
  end)}
end
```

## File Uploads

- [ ] Configure upload in mount with `allow_upload/3`
- [ ] Set `accept`, `max_entries`, `max_file_size`
- [ ] Implement "validate" event for live validation
- [ ] Implement "save" event to consume uploads
- [ ] Use `consume_uploaded_entries/3` to process files
- [ ] Handle upload errors in template

```elixir
@impl true
def mount(_params, _session, socket) do
  socket =
    socket
    |> assign(:uploaded_files, [])
    |> allow_upload(:image,
        accept: ~w(.jpg .jpeg .png .gif),
        max_entries: 5,
        max_file_size: 10_000_000
      )

  {:ok, socket}
end

@impl true
def handle_event("validate", _params, socket) do
  {:noreply, socket}
end

@impl true
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
      dest = Path.join(upload_dir(), entry.client_name)
      File.cp!(path, dest)

      Media.create_image(%{
        filename: entry.client_name,
        file_path: dest,
        content_type: entry.client_type,
        file_size: entry.client_size
      })
    end)

  {:noreply, update(socket, :images, &(&1 ++ uploaded_files))}
end
```

## Templates

- [ ] Use HEEx syntax `~H"""`
- [ ] Bind events with `phx-click`, `phx-submit`, etc.
- [ ] Use components with `<.component_name />`
- [ ] Handle upload errors with `@uploads.image.errors`
- [ ] Show loading states during operations

```heex
<.simple_form for={@form} phx-change="validate" phx-submit="save">
  <.input field={@form[:title]} label="Title" />

  <div phx-drop-target={@uploads.image.ref}>
    <.live_file_input upload={@uploads.image} />
  </div>

  <%= for entry <- @uploads.image.entries do %>
    <div>
      <.live_img_preview entry={entry} />
      <progress value={entry.progress} max="100"><%= entry.progress %>%</progress>
    </div>
  <% end %>

  <:actions>
    <.button phx-disable-with="Uploading...">Upload</.button>
  </:actions>
</.simple_form>
```

## Navigation

- [ ] Use `push_navigate/2` for different LiveViews
- [ ] Use `push_patch/2` for same LiveView with different params
- [ ] Use `~p` sigil for paths
- [ ] Handle navigation in event handlers

```elixir
# Navigate to different LiveView
{:noreply, push_navigate(socket, to: ~p"/settings")}

# Patch URL (same LiveView)
{:noreply, push_patch(socket, to: ~p"/gallery/#{folder_id}")}
```

## Flash Messages

- [ ] Use `put_flash/3` for user feedback
- [ ] Clear flash with `clear_flash/2` when needed
- [ ] Use `:info` for success, `:error` for failures

```elixir
socket = put_flash(socket, :info, "Image uploaded successfully")
socket = put_flash(socket, :error, "Upload failed")
```

## Testing

- [ ] Test mount behavior
- [ ] Test events with `render_click/2`, `render_submit/2`
- [ ] Test file uploads with `file_input/4` and `render_upload/2`
- [ ] Verify assigns are updated correctly
- [ ] Check flash messages appear

```elixir
test "uploads and displays image", %{conn: conn} do
  {:ok, lv, _html} = live(conn, "/gallery")

  image = file_input(lv, "#upload-form", :image, [
    %{name: "test.png", content: File.read!("test/fixtures/test.png")}
  ])

  assert render_upload(image, "test.png") =~ "100%"

  lv
  |> form("#upload-form")
  |> render_submit()

  assert has_element?(lv, "img[alt='test.png']")
end
```

## Performance

- [ ] Use streams for large lists: `stream(socket, :images, images)`
- [ ] Use temporary assigns for data that doesn't need to persist
- [ ] Debounce frequent events (search, etc.)
- [ ] Minimize data in socket assigns
- [ ] Preload associations to avoid N+1 queries

## Common Pitfalls

❌ **Don't** perform expensive operations in render
❌ **Don't** forget to add `@impl true`
❌ **Don't** subscribe to PubSub when not connected
❌ **Don't** modify socket after `push_navigate/2`
❌ **Don't** use `socket.assigns` in templates (use `@assign_name`)

✅ **Do** handle both connected and disconnected mount
✅ **Do** use pattern matching in event handlers
✅ **Do** return proper tuples from callbacks
✅ **Do** validate uploads before processing
✅ **Do** provide user feedback with flash messages

---

## Condensed Rules for Subagents

### LiveView Rules
1. Always add @impl true before every callback
2. Initialize assigns before they're accessed in render/1 — use mount/3 for static defaults, handle_params/3 for URL-dependent assigns
3. Check connected?(socket) before PubSub subscriptions or side effects
4. Return proper tuples — {:ok, socket} from mount, {:noreply, socket} from handle_event
5. Never use auto_upload: true with form submission
6. Check core_components.ex before creating custom components
7. Never query the database directly from LiveViews — use context functions

### LiveView Auth Rules
1. Use on_mount callbacks for LiveView auth — never check in mount/3 directly
2. Use mount_current_scope/2 to extract scope from session
3. Handle both :cont and :halt returns from on_mount
4. Use assigns[:current_scope] (bracket access) in templates — dot access crashes on nil
5. Test auth redirects with {:error, {:redirect, %{to: path}}}
6. Define on_mount hooks once, reference via live_session in router

### PubSub Rules
1. Guard subscriptions with if connected?(socket)
2. Broadcast from contexts, not LiveViews
3. Use consistent topic naming — resource:id for specific, resource:action for collection
4. Handle PubSub messages in handle_info/2, never handle_event/3
5. Update assigns immutably with update/3

### Upload Rules
1. Use manual uploads, not auto_upload: true
2. Add upload directory to static_paths()
3. Generate unique filenames — prevent collisions and path traversal
4. Validate file types server-side

## Project Structure

# Project Structure

## Directory Layout

```
my_app/
├── lib/
│   ├── my_app/              # Core application logic
│   │   ├── application.ex   # Application entry point
│   │   ├── media/           # Media context
│   │   │   ├── image.ex     # Image schema
│   │   │   ├── folder.ex    # Folder schema
│   │   │   └── media.ex     # Context boundary module
│   │   └── repo.ex          # Ecto repository
│   │
│   └── my_app_web/          # Web interface
│       ├── components/      # Reusable UI components
│       ├── controllers/     # Traditional controllers
│       ├── live/            # LiveView modules
│       │   └── gallery_live.ex
│       ├── endpoint.ex      # Phoenix endpoint
│       ├── router.ex        # Route definitions
│       └── telemetry.ex     # Metrics and monitoring
│
├── priv/
│   ├── repo/
│   │   └── migrations/      # Database migrations
│   ├── static/              # Static assets
│   │   └── uploads/         # Uploaded images
│   └── gettext/             # Translations
│
├── test/
│   ├── my_app/              # Tests for core logic
│   │   └── media_test.exs
│   ├── my_app_web/          # Tests for web layer
│   │   └── live/
│   │       └── gallery_live_test.exs
│   ├── support/             # Test helpers
│   └── test_helper.exs
│
├── config/
│   ├── config.exs           # General config
│   ├── dev.exs              # Development config
│   ├── test.exs             # Test config
│   ├── prod.exs             # Production config
│   └── runtime.exs          # Runtime config
│
├── assets/                  # Frontend assets
│   ├── css/
│   ├── js/
│   └── vendor/
│
└── mix.exs                  # Project definition
```

## Context Boundaries

Phoenix encourages organizing code into contexts - modules that group related functionality.

### Media Context

The `Media` context handles all image and folder operations:

```elixir
# lib/my_app/media.ex - Public API
defmodule MyApp.Media do
  # Public functions that other contexts can call
  def list_images()
  def get_image!(id)
  def create_image(attrs)
  def update_image(image, attrs)
  def delete_image(image)

  def list_folders()
  def create_folder(attrs)
  def move_image_to_folder(image, folder)
end

# lib/my_app/media/image.ex - Schema
defmodule MyApp.Media.Image do
  use Ecto.Schema
  # Schema definition only
end

# lib/my_app/media/folder.ex - Schema
defmodule MyApp.Media.Folder do
  use Ecto.Schema
  # Schema definition only
end
```

### Web Layer

The web layer should be thin, delegating business logic to contexts:

```elixir
# lib/my_app_web/live/gallery_live.ex
defmodule MyAppWeb.GalleryLive do
  use MyAppWeb, :live_view

  alias MyApp.Media  # Import the context

  def handle_event("upload", params, socket) do
    # Delegate to context
    case Media.create_image(params) do
      {:ok, image} -> # Handle success
      {:error, changeset} -> # Handle error
    end
  end
end
```

## File Organization Rules

1. **One module per file**: File path should match module name
   - `MyApp.Media.Image` → `lib/my_app/media/image.ex`

2. **Contexts group related functionality**:
   - Keep schemas in context directory
   - Public API in main context module

3. **Web vs. Core**:
   - `lib/my_app/` = business logic, no web dependencies
   - `lib/my_app_web/` = web interface, depends on core

4. **Test mirrors source**:
   - `lib/my_app/media.ex` → `test/my_app/media_test.exs`

## Common Files

### application.ex
Starts the application and supervision tree:
```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,           # Database
    MyAppWeb.Telemetry,   # Metrics
    MyAppWeb.Endpoint     # Web server
  ]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### router.ex
Defines routes:
```elixir
scope "/", MyAppWeb do
  pipe_through :browser

  live "/", GalleryLive, :index
  live "/folder/:id", GalleryLive, :folder
end
```

### repo.ex
Database access:
```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

## Configuration

Configuration is environment-specific:

- `config/config.exs` - Shared configuration
- `config/dev.exs` - Development (imports config.exs)
- `config/test.exs` - Test environment
- `config/prod.exs` - Production
- `config/runtime.exs` - Runtime configuration (env vars)

## Assets

Frontend assets in `assets/`:
- Compiled by esbuild
- Output to `priv/static/`
- Served by Phoenix endpoint

## Key Principles

1. **Contexts are boundaries**: Don't bypass contexts to access schemas directly from web layer
2. **Thin controllers/LiveViews**: Business logic goes in contexts
3. **One source of truth**: Each piece of data belongs to one context
4. **Dependencies flow inward**: Web depends on core, not vice versa

---

## Condensed Rules for Subagents

### Elixir Rules
1. Use pattern matching over if/else for control flow
2. Add @impl true before every callback function
3. Return {:ok, result} | {:error, reason} tuples for fallible operations
4. Use with for 2+ sequential fallible operations
5. Use the pipe operator for 2+ chained transformations
6. Never nest if/else — use case, cond, or multi-clause functions
7. Let it crash — no defensive code for impossible states

### Deployment Rules
1. Use runtime.exs for secrets and URLs — config.exs/prod.exs are compiled into the release
2. Run migrations via release commands (bin/migrate)
3. Set PHX_HOST and PHX_SERVER=true
4. Run mix assets.deploy before building the release
5. Never hardcode secrets — use System.get_env!/1 in runtime.exs
6. Add a /health endpoint that queries the database

### Code Quality Rules
1. Extract duplicated functions (>70% similar) into shared modules
2. Keep function ABC complexity below 30
3. Remove unused private functions
4. Extract duplicated template markup into function components

## Testing Guide

# Testing Guide for Elixir/Phoenix

> **Reference companion to `elixir-phoenix-guide:testing-essentials`** — invoke the skill before writing any test file. This doc provides detailed examples; the skill provides the rules and workflow.

## Test Structure

```elixir
defmodule MyApp.MediaTest do
  use MyApp.DataCase, async: true

  alias MyApp.Media

  describe "images" do
    test "list_images/0 returns all images" do
      image = insert_image()
      assert Media.list_images() == [image]
    end

    test "create_image/1 with valid data creates an image" do
      attrs = valid_image_attributes()
      assert {:ok, %Image{} = image} = Media.create_image(attrs)
      assert image.title == attrs.title
    end
  end
end
```

## Testing Contexts

```elixir
defmodule MyApp.MediaTest do
  use MyApp.DataCase

  alias MyApp.Media
  alias MyApp.Media.Image

  describe "list_images/0" do
    test "returns all images" do
      image1 = insert_image(title: "First")
      image2 = insert_image(title: "Second")

      images = Media.list_images()

      assert length(images) == 2
      assert Enum.any?(images, & &1.id == image1.id)
      assert Enum.any?(images, & &1.id == image2.id)
    end

    test "returns empty list when no images exist" do
      assert Media.list_images() == []
    end
  end

  describe "create_image/1" do
    test "with valid attributes creates image" do
      attrs = %{
        title: "Test Image",
        filename: "test.jpg",
        file_path: "/uploads/test.jpg",
        content_type: "image/jpeg",
        file_size: 1024
      }

      assert {:ok, %Image{} = image} = Media.create_image(attrs)
      assert image.title == "Test Image"
      assert image.filename == "test.jpg"
    end

    test "with invalid attributes returns error changeset" do
      attrs = %{title: ""}

      assert {:error, %Ecto.Changeset{}} = Media.create_image(attrs)
    end
  end

  describe "update_image/2" do
    test "with valid attributes updates image" do
      image = insert_image()
      attrs = %{title: "Updated Title"}

      assert {:ok, %Image{} = updated} = Media.update_image(image, attrs)
      assert updated.title == "Updated Title"
    end
  end

  describe "delete_image/1" do
    test "deletes the image" do
      image = insert_image()

      assert {:ok, %Image{}} = Media.delete_image(image)
      assert_raise Ecto.NoResultsError, fn -> Media.get_image!(image.id) end
    end
  end

  # Test helpers
  defp insert_image(attrs \\ %{}) do
    defaults = %{
      title: "Test Image",
      filename: "test.jpg",
      file_path: "/uploads/test.jpg",
      content_type: "image/jpeg",
      file_size: 1024
    }

    {:ok, image} =
      defaults
      |> Map.merge(attrs)
      |> Media.create_image()

    image
  end
end
```

## Testing LiveViews

```elixir
defmodule MyAppWeb.GalleryLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  alias MyApp.Media

  describe "Index" do
    test "displays all images", %{conn: conn} do
      image = insert_image(title: "Sunset")

      {:ok, _lv, html} = live(conn, "/gallery")

      assert html =~ "Sunset"
    end

    test "uploads new image", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/gallery")

      image =
        file_input(lv, "#upload-form", :image, [
          %{
            name: "test.png",
            content: File.read!("test/support/fixtures/test.png"),
            type: "image/png"
          }
        ])

      assert render_upload(image, "test.png") =~ "100%"

      html =
        lv
        |> form("#upload-form", image: %{title: "Test Upload"})
        |> render_submit()

      assert html =~ "Test Upload"
    end

    test "deletes image", %{conn: conn} do
      image = insert_image(title: "To Delete")

      {:ok, lv, _html} = live(conn, "/gallery")

      html =
        lv
        |> element("#image-#{image.id} button", "Delete")
        |> render_click()

      refute html =~ "To Delete"
    end

    test "creates folder", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/gallery")

      html =
        lv
        |> form("#folder-form", folder: %{name: "Vacation"})
        |> render_submit()

      assert html =~ "Vacation"
    end

    test "moves image to folder", %{conn: conn} do
      image = insert_image()
      folder = insert_folder(name: "Vacation")

      {:ok, lv, _html} = live(conn, "/gallery")

      lv
      |> element("#image-#{image.id} form")
      |> render_change(%{folder_id: folder.id})

      lv
      |> element("#image-#{image.id} form")
      |> render_submit()

      assert Media.get_image!(image.id).folder_id == folder.id
    end
  end

  describe "navigation" do
    test "navigates to folder view", %{conn: conn} do
      folder = insert_folder(name: "Vacation")

      {:ok, lv, _html} = live(conn, "/gallery")

      {:ok, _lv, html} =
        lv
        |> element("#folder-#{folder.id}")
        |> render_click()
        |> follow_redirect(conn, "/gallery/folder/#{folder.id}")

      assert html =~ "Vacation"
    end
  end
end
```

## Testing Schemas and Changesets

```elixir
defmodule MyApp.Media.ImageTest do
  use MyApp.DataCase

  alias MyApp.Media.Image

  describe "changeset/2" do
    test "valid attributes" do
      attrs = %{
        title: "Test",
        filename: "test.jpg",
        file_path: "/uploads/test.jpg",
        content_type: "image/jpeg",
        file_size: 1024
      }

      changeset = Image.changeset(%Image{}, attrs)

      assert changeset.valid?
    end

    test "requires title" do
      attrs = %{filename: "test.jpg"}

      changeset = Image.changeset(%Image{}, attrs)

      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates title length" do
      attrs = %{title: String.duplicate("a", 256)}

      changeset = Image.changeset(%Image{}, attrs)

      refute changeset.valid?
      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "validates file_size is positive" do
      attrs = %{file_size: -1}

      changeset = Image.changeset(%Image{}, attrs)

      refute changeset.valid?
      assert %{file_size: ["must be greater than 0"]} = errors_on(changeset)
    end
  end
end
```

## Test Helpers

Create helper functions in `test/support/`:

```elixir
defmodule MyApp.MediaFixtures do
  @moduledoc """
  Fixtures for Media context.
  """

  alias MyApp.Media

  def unique_image_title, do: "Image #{System.unique_integer([:positive])}"

  def valid_image_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      title: unique_image_title(),
      filename: "test.jpg",
      file_path: "/uploads/test.jpg",
      content_type: "image/jpeg",
      file_size: 1024
    })
  end

  def image_fixture(attrs \\ %{}) do
    {:ok, image} =
      attrs
      |> valid_image_attributes()
      |> Media.create_image()

    image
  end

  def folder_fixture(attrs \\ %{}) do
    {:ok, folder} =
      Enum.into(attrs, %{name: "Folder #{System.unique_integer()}"})
      |> Media.create_folder()

    folder
  end
end
```

## Async Tests

Tests can run concurrently when they don't share state:

```elixir
use MyApp.DataCase, async: true  # Safe - each test gets own sandbox

test "creates image", %{conn: conn} do
  # This test is isolated
end
```

Don't use `async: true` when:
- Tests modify global state
- Tests interact with external services
- Tests require specific test order

## Mocking

Use Mox for mocking:

```elixir
# In test/support/mocks.ex
Mox.defmock(MyApp.StorageMock, for: MyApp.Storage.Behaviour)

# In test
import Mox

test "uploads file" do
  expect(MyApp.StorageMock, :upload, fn _file ->
    {:ok, "/uploads/test.jpg"}
  end)

  # Test code that calls Storage.upload/1
end
```

## Testing Ecto Queries

```elixir
test "filters images by folder" do
  folder = insert_folder()
  image1 = insert_image(folder_id: folder.id)
  image2 = insert_image()  # No folder

  images = Media.list_images_by_folder(folder.id)

  assert length(images) == 1
  assert hd(images).id == image1.id
end
```

## Testing File Uploads in LiveView

```elixir
test "validates upload file types", %{conn: conn} do
  {:ok, lv, _html} = live(conn, "/gallery")

  # Try uploading invalid file type
  image =
    file_input(lv, "#upload-form", :image, [
      %{name: "test.pdf", content: "fake pdf", type: "application/pdf"}
    ])

  # Should show error
  assert render(lv) =~ "You have selected an unacceptable file type"
end

test "validates upload file size", %{conn: conn} do
  {:ok, lv, _html} = live(conn, "/gallery")

  large_content = :crypto.strong_rand_bytes(11_000_000)

  image =
    file_input(lv, "#upload-form", :image, [
      %{name: "large.jpg", content: large_content, type: "image/jpeg"}
    ])

  assert render(lv) =~ "Too large"
end
```

## Common Assertions

```elixir
# Equality
assert value == expected

# Pattern matching
assert {:ok, %Image{}} = result

# Presence
assert value
refute value

# Raise/throw
assert_raise ArgumentError, fn -> dangerous_function() end

# Database
assert Repo.get(Image, id)
assert Repo.aggregate(Image, :count) == 1

# In list
assert image in images
assert Enum.member?(images, image)

# HTML content (in tests)
assert html =~ "Expected text"
assert has_element?(lv, "#element-id")

# Flash messages
assert lv |> render() =~ "Successfully created"
```

## Test Organization

```
test/
├── my_app/
│   ├── media_test.exs          # Context tests
│   └── media/
│       ├── image_test.exs       # Schema tests
│       └── folder_test.exs
├── my_app_web/
│   ├── live/
│   │   └── gallery_live_test.exs
│   └── controllers/
│       └── page_controller_test.exs
├── support/
│   ├── conn_case.ex
│   ├── data_case.ex
│   ├── fixtures/
│   │   └── test.png
│   └── fixtures.ex              # Fixture helpers
└── test_helper.exs
```

---

## Condensed Rules for Subagents

### Testing Rules
1. Use DataCase for DB tests, ConnCase for LiveView/controller tests
2. Test both happy path AND error cases
3. Use async: true only when safe
4. Define test data in fixtures — never inline across tests
5. Use has_element?/2 for LiveView assertions
6. Always test the unauthorized case

