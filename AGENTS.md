# Elixir Phoenix Guide — Agent Reference

Longer reference material behind the instructions in `.github/instructions/`.
Generated from elixir-phoenix-guide; edit the canonical skills, not this file.

## Ecto Reference


> Verified against Elixir 1.20, Ecto 3.14, ecto_sql 3.14 (PostgreSQL) — October 2026

Cheat sheets for the `ecto-essentials` skill. Examples use its `Image` schema (images in folders).

### Field Types

| Type | Postgres | Use for |
|---|---|---|
| `:string` | `varchar(255)` | Short text (titles, names) |
| `:string` in schema, `:text` in migration | `text` | Long text — the schema type stays `:string` |
| `:integer` | `integer` / `bigint` | Counts, sizes |
| `:float` | `double precision` | Measurements where rounding error is acceptable — **never money** |
| `:decimal` | `numeric` | Money and exact values (returns `Decimal` structs — compare with `Decimal.compare/2`, not `==`) |
| `:boolean` | `boolean` | Flags |
| `:date`, `:time` | `date`, `time` | Calendar dates, wall-clock times |
| `:utc_datetime` | `timestamp(0)` | Timestamps to the second — the Phoenix 1.8 default |
| `:utc_datetime_usec` | `timestamp` | Timestamps where ordering within a second matters |
| `:naive_datetime` | `timestamp(0)` | Avoid — no timezone; the pre-1.8 `timestamps()` default |
| `:binary` | `bytea` | Raw bytes (tokens, hashes) |
| `:binary_id` | `uuid` | UUID keys: `@primary_key {:id, :binary_id, autogenerate: true}` plus `@foreign_key_type :binary_id` |
| `:map` | `jsonb` | Free-form JSON (keys come back as strings) |
| `{:array, :string}` | `varchar[]` | Tags, small lists of scalars |
| `Ecto.Enum` | `varchar` (or a Postgres enum) | Closed sets: `field :status, Ecto.Enum, values: [:draft, :published]` |

`citext` (case-insensitive text) is a migration type: `add :email, :citext` after `execute "CREATE EXTENSION IF NOT EXISTS citext", ""`. The schema field stays `:string`.

### Associations

```elixir
belongs_to :folder, MyApp.Media.Folder          # owns the folder_id column
has_many :images, MyApp.Media.Image             # images.folder_id points here
has_one :profile, MyApp.Accounts.Profile
many_to_many :tags, MyApp.Media.Tag, join_through: "images_tags", on_replace: :delete
has_many :comments_on_images, through: [:images, :comments]
```

### Validators

```elixir
changeset
|> validate_required([:title, :body])
|> validate_length(:title, min: 1, max: 255)
|> validate_length(:password, max: 72, count: :bytes)
|> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
|> validate_inclusion(:content_type, ~w(image/jpeg image/png))
|> validate_exclusion(:username, ~w(admin root))
|> validate_number(:price, greater_than_or_equal_to: 0)
|> validate_confirmation(:password, message: "does not match password")
|> validate_acceptance(:terms_of_service)
|> validate_change(:url, fn :url, url ->
  if String.starts_with?(url, "https://"), do: [], else: [url: "must use https"]
end)
```

### Constraint Functions

Each needs the matching database object; without it the error raises instead of landing in the changeset.

```elixir
changeset
|> unique_constraint(:email)                                    # unique_index(:users, [:email])
|> unique_constraint(:name, name: :folders_user_id_name_index)  # composite or custom-named index
|> foreign_key_constraint(:folder_id)                           # references(:folders)
|> check_constraint(:price, name: :price_must_be_positive)      # create constraint(...)
|> no_assoc_constraint(:images)                                 # on delete: block if children exist
```

`no_assoc_constraint/3` goes on the parent's delete changeset and pairs with `on_delete: :restrict` (or `:nothing`) on the child's reference:

```elixir
folder
|> Ecto.Changeset.change()
|> Ecto.Changeset.no_assoc_constraint(:images)
|> Repo.delete()
```

### Changeset Actions

Errors only render once the changeset has an action. In LiveView, `to_form(changeset, action: :validate)` sets it so errors show while typing. Outside a Repo call, `Ecto.Changeset.apply_action(changeset, :insert)` returns `{:ok, struct}` or `{:error, changeset}` with the action set.

### Query Syntax

```elixir
import Ecto.Query

# Keyword syntax and pipe syntax are equivalent
from i in Image, where: i.user_id == ^user_id and i.byte_size > 1000, order_by: [desc: i.inserted_at]

Image
|> where([i], i.user_id == ^user_id)
|> order_by([i], desc: i.inserted_at, desc: i.id)
|> limit(20)

# One row from a query that may match many — Repo.one/1 alone raises MultipleResultsError
query |> first(:inserted_at) |> Repo.one()

# Select a map or a subset
from i in Image, select: %{id: i.id, title: i.title}

# Joins
from i in Image, join: f in assoc(i, :folder), where: f.name == ^name
from i in Image, left_join: f in assoc(i, :folder), select: {i, f}

# Preloads: nested, and with a custom query
from f in Folder, preload: [images: :tags]
recent = from i in Image, order_by: [desc: i.inserted_at], limit: 5
from f in Folder, preload: [images: ^recent]

# Aggregates
Repo.aggregate(Image, :count)
Repo.aggregate(from(i in Image, where: i.user_id == ^user_id), :sum, :byte_size)
from(i in Image, group_by: i.folder_id, select: {i.folder_id, count(i.id)}) |> Repo.all() |> Map.new()

# NULL ordering
from i in Image, order_by: [asc_nulls_last: i.folder_id]
from i in Image, order_by: [desc_nulls_first: i.priority]

# Exists / fetch by several fields
Repo.exists?(from i in Image, where: i.folder_id == ^folder_id)
Repo.all_by(Image, folder_id: folder_id, user_id: user_id)
```

Preloading a custom query with `limit` limits across **all** parents, not per parent. For "latest N per parent" use a lateral join or a window function.

### Repo Return Shapes

| Call | Returns |
|---|---|
| `get/2`, `get_by/2`, `one/1` | struct or `nil` (`one` raises on >1 row) |
| `get!/2`, `get_by!/2`, `one!/1` | struct or raises `Ecto.NoResultsError` |
| `insert/2`, `update/2`, `delete/2` | `{:ok, struct}` or `{:error, changeset}` |
| `insert!/2`, `update!/2`, `delete!/2` | struct or raises `Ecto.InvalidChangesetError` |
| `insert_all/3`, `update_all/3`, `delete_all/2` | `{count, nil \| returned_rows}` — no changesets, no timestamps, constraint violations raise |
| `transact/2` | whatever the function returned: `{:ok, _}` or `{:error, _}` |

### Migration Operations

All of these are reversible inside `change/0`:

```elixir
alter table(:images) do
  add :priority, :integer, default: 0, null: false
  remove :legacy_path, :string
  modify :title, :text, from: :string
end

rename table(:images), :name, to: :title
rename table(:pictures), to: table(:images)

create index(:images, [:title])
create unique_index(:folders, [:user_id, :name])
create index(:images, [:user_id], where: "deleted_at IS NULL", name: :images_live_user_id_index)
drop index(:images, [:title])

create constraint(:images, :byte_size_must_be_positive, check: "byte_size > 0")

execute "CREATE EXTENSION IF NOT EXISTS citext", ""
```

Not reversible in `change/0`: `remove/1` (no type), `modify/3` without `from:`, `execute/1`, `remove_if_exists`, `drop table(...)`, `drop constraint(...)`. Use the forms above or write `up/0` and `down/0`.

Generate with `mix ecto.gen.migration create_images`; never edit a migration that has already run in another environment — add a new one.

### Soft Delete

`deleted_at` is a privileged field: don't `cast` it. Set it directly.

```elixir
# Schema
field :deleted_at, :utc_datetime

# Context: every read filters it, e.g. list_images/2
def list_images(%Scope{} = scope, filters \\ []) do
  Image
  |> where([i], i.user_id == ^scope.user.id and is_nil(i.deleted_at))
  |> filter_images(filters)
  |> Repo.all()
end

def soft_delete_image(%Scope{} = scope, %Image{} = image) do
  true = image.user_id == scope.user.id

  image
  |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
  |> Repo.update()
end
```

<!-- epg:bad -->
```elixir
# Silently does nothing: Image.changeset/3 doesn't cast :deleted_at
def soft_delete_image(scope, image), do: update_image(scope, image, %{deleted_at: DateTime.utc_now()})
```

Every read path must filter `is_nil(deleted_at)`, and unique indexes need `where: "deleted_at IS NULL"` so a deleted row doesn't block re-creating the same name.

## Phoenix Project Structure


> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 (a freshly generated app) — October 2026

The layout `mix phx.new my_app` (Phoenix 1.8) generates, plus `mix phx.gen.auth Accounts User users --live` and a `Media` context.

### Directory Layout

```text
my_app/
├── lib/
│   ├── my_app.ex                    # Top-level module (docs only)
│   ├── my_app/                      # Business logic, no web dependencies
│   │   ├── application.ex           # Supervision tree
│   │   ├── repo.ex                  # Ecto repository
│   │   ├── mailer.ex                # Swoosh mailer
│   │   ├── accounts.ex              # Accounts context: public API (phx.gen.auth)
│   │   ├── accounts/
│   │   │   ├── scope.ex             # %Scope{} passed first to every context call
│   │   │   ├── user.ex              # Schema
│   │   │   ├── user_token.ex
│   │   │   └── user_notifier.ex     # Login/confirmation emails
│   │   ├── media.ex                 # Media context: public API
│   │   └── media/
│   │       ├── image.ex             # Schema
│   │       └── folder.ex            # Schema
│   │
│   ├── my_app_web.ex                # `use MyAppWeb, :live_view` / :controller / :html
│   └── my_app_web/
│       ├── components/
│       │   ├── core_components.ex   # <.input>, <.button>, <.table>, <.header>, <.icon>, <.flash>
│       │   ├── layouts.ex           # Layouts.app/1 function component, flash_group
│       │   └── layouts/
│       │       └── root.html.heex   # <html> shell, the only layout template
│       ├── controllers/
│       │   ├── page_controller.ex
│       │   ├── page_html.ex         # View module: embed_templates "page_html/*"
│       │   ├── page_html/
│       │   │   └── home.html.heex
│       │   ├── error_html.ex        # Error pages (HTML)
│       │   ├── error_json.ex        # Error bodies (JSON); API views are *_json.ex
│       │   └── user_session_controller.ex
│       ├── live/
│       │   ├── image_live/
│       │   │   ├── index.ex
│       │   │   ├── show.ex
│       │   │   └── form.ex
│       │   └── user_live/           # Registration, login, settings, confirmation
│       ├── user_auth.ex             # Auth plugs and on_mount hooks
│       ├── endpoint.ex
│       ├── router.ex
│       ├── telemetry.ex             # Metrics and telemetry poller
│       └── gettext.ex
│
├── priv/
│   ├── repo/
│   │   ├── migrations/
│   │   └── seeds.exs                # `mix run priv/repo/seeds.exs`
│   ├── static/                      # Build output + favicon.ico, robots.txt, images/
│   └── gettext/                     # Translations
│
├── assets/
│   ├── css/app.css                  # Tailwind v4 entry (@import "tailwindcss", daisyUI @plugin)
│   ├── js/app.js                    # esbuild entry (LiveSocket, hooks)
│   └── vendor/                      # heroicons.js, topbar.js
│
├── test/
│   ├── my_app/
│   │   └── media_test.exs
│   ├── my_app_web/
│   │   └── live/
│   │       └── image_live_test.exs
│   ├── support/
│   │   ├── conn_case.ex             # ConnCase: register_and_log_in_user/1
│   │   ├── data_case.ex             # DataCase: sandbox setup, errors_on/1
│   │   └── fixtures/
│   │       ├── accounts_fixtures.ex # user_fixture/1, user_scope_fixture/0
│   │       └── media_fixtures.ex
│   └── test_helper.exs
│
├── config/
│   ├── config.exs                   # Shared; imports "#{config_env()}.exs" at the bottom
│   ├── dev.exs
│   ├── test.exs
│   ├── prod.exs                     # Compile-time prod settings
│   └── runtime.exs                  # Env vars, read at boot (releases too)
│
├── rel/                             # Created by `mix phx.gen.release` (overlays, env.sh.eex)
├── AGENTS.md                        # Usage rules Phoenix 1.8 generates for coding agents
└── mix.exs                          # Deps and aliases (setup, assets.build, assets.deploy)
```

There is no `tailwind.config.js` in Phoenix 1.8: Tailwind v4 is configured in `assets/css/app.css`. Both tailwind and esbuild run as Mix deps (no Node required) via `config :tailwind` / `config :esbuild` and the dev watchers.

### Context Boundaries

The context module sits next to its directory: `lib/my_app/media.ex` holds the public API, `lib/my_app/media/*.ex` holds schemas. Following the 1.8 generators, every function takes the caller's `%Scope{}` first:

```elixir
# lib/my_app/media.ex
defmodule MyApp.Media do
  alias MyApp.Accounts.Scope
  alias MyApp.Media.Image
  alias MyApp.Repo

  def get_image!(%Scope{} = scope, id), do: Repo.get_by!(Image, id: id, user_id: scope.user.id)

  # list_images/2, create_image/3, update_image/3, delete_image/2: see the ecto-essentials skill
end
```

The full scoped context is in the `ecto-essentials` skill (queries) and the `phoenix-pubsub-patterns` skill (the generated module with broadcasts). The web layer stays thin and passes `socket.assigns.current_scope`:

```elixir
# lib/my_app_web/live/image_live/form.ex
@impl true
def handle_event("save", %{"image" => image_params}, socket) do
  %{current_scope: scope, image: image} = socket.assigns

  case Media.update_image(scope, image, image_params) do
    {:ok, _image} ->
      {:noreply,
       socket
       |> put_flash(:info, "Image updated")
       |> push_navigate(to: ~p"/images")}

    {:error, %Ecto.Changeset{} = changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

### File Organization Rules

1. **One module per file; the path mirrors the module name.** `MyApp.Media.Image` → `lib/my_app/media/image.ex`, `MyApp.Media` → `lib/my_app/media.ex`.
2. **`lib/my_app/` never references `MyAppWeb`.** Dependencies flow from web to core.
3. **Tests mirror source.** `lib/my_app/media.ex` → `test/my_app/media_test.exs`.
4. **Controllers render through a view module.** `PageController` → `PageHTML` (`page_html.ex` + `page_html/*.heex`); JSON APIs use `*_json.ex` modules returning maps.
5. **Shared UI goes in `core_components.ex`** (or a new module under `components/`), not in each LiveView.

### application.ex

The generated supervision tree, in start order. Add Oban (and your own processes) before the Endpoint so they are running when requests arrive:

```elixir
def start(_type, _args) do
  children = [
    MyAppWeb.Telemetry,
    MyApp.Repo,
    {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},
    {Phoenix.PubSub, name: MyApp.PubSub},
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # Start to serve requests, typically the last entry
    MyAppWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Configuration

- `config/config.exs` is read first and ends with `import_config "#{config_env()}.exs"`, so `dev.exs`, `test.exs` or `prod.exs` override it. The environment files don't import `config.exs`.
- `config/runtime.exs` runs at boot, after compilation, in dev, test and releases. Secrets and `DATABASE_URL`/`SECRET_KEY_BASE` go here, never in `prod.exs`.
- Repeated `config :my_app, Key, ...` calls deep-merge keyword lists; any other value (including a list that isn't a keyword list) is replaced by the later call.

### Static files and uploads

`priv/static` holds build output and is served only for the paths in `MyAppWeb.static_paths/0` (`assets fonts images favicon.ico robots.txt`). Don't store user uploads there: a release is rebuilt and replaced on every deploy, so uploaded files disappear. Store uploads in external storage (S3 or compatible) or a configured directory on a mounted volume: public files served by their own `Plug.Static` in the endpoint, private ones by a controller that loads the record through the scope. See the `phoenix-uploads` skill.

### Key Principles

1. **Contexts are boundaries.** The web layer calls context functions, never `Repo` or schemas' queries directly.
2. **Scope every call.** Pass `current_scope` into the context; never load or delete a record by a client-supplied id alone.
3. **Thin controllers and LiveViews.** Business logic lives in contexts.
4. **One owner per piece of data.** Each table belongs to one context.

## LiveView Checklist


> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

Walk through this before finishing or reviewing a LiveView. Each section has a checklist and,
where it helps, a reference snippet. The examples build one gallery LiveView: images in folders,
owned by the current user, with uploads.

Assumed context API (Phoenix 1.8 style, scope first; the `Image` schema is the one in the
`ecto-essentials` skill): `Media.list_folders(scope)`, `Media.get_folder!(scope, id)`,
`Media.list_images(scope, filters \\ [])`, `Media.get_image!(scope, id)`,
`Media.create_image(scope, tmp_path, attrs)`, `Media.delete_image(scope, image)`,
`Media.image_url(image)`, and `Media.subscribe_images(scope)`, which delivers
`{:created | :updated | :deleted, %Image{}}`.

### Module Setup

- [ ] `use MyAppWeb, :live_view` (brings in `JS`, core components, `~p`, `Layouts`)
- [ ] `@impl true` before every callback
- [ ] Render wraps content in `<Layouts.app flash={@flash} current_scope={@current_scope}>`
- [ ] The route sits in a `live_session` whose `on_mount` assigns `current_scope` (see the `phoenix-liveview-auth` skill)

### Mount

- [ ] Every assign the template reads is set here or in `handle_params/3`
- [ ] PubSub subscriptions and timers only inside `if connected?(socket)`, and only here
- [ ] Collections are streams; small fixed lists (folders, options) may be plain assigns
- [ ] Slow or optional data uses `assign_async` / `stream_async`, not a blocking query
- [ ] Returns `{:ok, socket}`

```elixir
@impl true
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope

  if connected?(socket) do
    Media.subscribe_images(scope)
  end

  {:ok,
   socket
   |> assign(:folders, Media.list_folders(scope))
   |> assign(:selected_folder, nil)
   |> stream(:images, [])
   |> assign(:form, to_form(%{"title" => ""}, as: :image))
   |> allow_upload(:images, accept: ~w(.jpg .jpeg .png .webp), max_entries: 5, max_file_size: 10_000_000)}
end
```

### Handle Params

- [ ] Present whenever URL params change what's shown (ids, filters, sort, page)
- [ ] Never subscribes — it re-runs on every `push_patch`
- [ ] Records loaded by URL id go through the scope (`get_folder!(scope, id)`)
- [ ] Refilters a stream with `reset: true`

```elixir
@impl true
def handle_params(%{"folder_id" => folder_id}, _uri, socket) do
  scope = socket.assigns.current_scope
  folder = Media.get_folder!(scope, folder_id)

  {:noreply,
   socket
   |> assign(:selected_folder, folder)
   |> stream(:images, Media.list_images(scope, folder_id: folder.id), reset: true)}
end

def handle_params(_params, _uri, socket) do
  {:noreply,
   socket
   |> assign(:selected_folder, nil)
   |> stream(:images, Media.list_images(socket.assigns.current_scope), reset: true)}
end
```

### Handle Event

- [ ] Every context call gets `socket.assigns.current_scope` first — an id from the client is never trusted on its own
- [ ] Load the record through the scope, then act on the struct (string params never compare equal to integer ids)
- [ ] Expected failures (`{:error, changeset}`, `{:error, :reason}`) become flash or form errors; only bugs crash
- [ ] Returns `{:noreply, socket}` (or `{:reply, map, socket}` for a hook's `pushEvent`)

```elixir
@impl true
def handle_event("delete_image", %{"id" => id}, socket) do
  scope = socket.assigns.current_scope
  image = Media.get_image!(scope, id)

  case Media.delete_image(scope, image) do
    {:ok, _} ->
      {:noreply,
       socket
       |> put_flash(:info, "Image deleted")
       |> stream_delete(:images, image)}

    {:error, _changeset} ->
      {:noreply, put_flash(socket, :error, "Failed to delete image")}
  end
end
```

### Handle Info

- [ ] Clauses match the exact broadcast shapes from the context (`{:created, %Image{}}`, ...)
- [ ] Updates the stream rather than refetching, unless order/filter makes that impractical (then `stream(..., reset: true)`)
- [ ] Multi-clause callbacks are grouped together, `@impl true` on the first

```elixir
@impl true
def handle_info({:created, %Image{} = image}, socket) do
  {:noreply, stream_insert(socket, :images, image, at: 0)}
end

def handle_info({:updated, %Image{} = image}, socket) do
  {:noreply, stream_insert(socket, :images, image)}
end

def handle_info({:deleted, %Image{} = image}, socket) do
  {:noreply, stream_delete(socket, :images, image)}
end
```

If a broadcast carries only an id, use `stream_delete_by_dom_id(socket, :images, "images-#{id}")`.

### Forms

- [ ] `@form` comes from `to_form/2`; templates never read a raw changeset
- [ ] `<.form>` has a unique `id`, `phx-change` and `phx-submit`
- [ ] `<.button>` is a direct child of `<.form>` (no actions slot — it would never render)
- [ ] The validate handler uses `to_form(changeset, action: :validate)`
- [ ] `phx-debounce` on inputs that hit the server on every keystroke
- [ ] `phx-disable-with` on submit buttons

### File Uploads

The `phoenix-uploads` skill has the full pattern (context, LiveView, template, tests). Check:

- [ ] `allow_upload/3` in mount with `accept`, `max_entries`, `max_file_size`
- [ ] The form has `phx-change` (even a no-op validate handler) so entries are tracked
- [ ] The callback given to `consume_uploaded_entries/3` returns `{:ok, value}` or `{:postpone, value}` — wrap the context result and handle `{:error, _}` after consuming
- [ ] The stored name and extension come from the server (UUID plus an extension picked from the sniffed content type), never from `entry.client_name` or `entry.client_type`
- [ ] Files are stored under a configured directory, not `priv/static`, and rendered through a helper (`Media.image_url(image)`)
- [ ] `upload_errors/1` and `upload_errors/2` are rendered, and `error_to_string/1` has a catch-all clause

### Templates

- [ ] `{@x}` for interpolation in text and attributes, never `<%= @x %>`
- [ ] `:for` / `:if` attributes instead of EEx `for` / `if` blocks
- [ ] Stream containers have an `id` and `phx-update="stream"`; each child uses the stream's `dom_id`
- [ ] `:for` over a plain list has a `:key`
- [ ] Function components declare `attr` / `slot` (with `default:` for optional attrs)
- [ ] Loading states for async assigns via `<.async_result>`
- [ ] Every element with `phx-hook` has a unique `id`

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <%!-- Upload form (#upload-form, @uploads.images): see the phoenix-uploads skill --%>

  <div id="images" phx-update="stream">
    <div :for={{dom_id, image} <- @streams.images} id={dom_id}>
      <img src={Media.image_url(image)} alt={image.title} />
      <.button phx-click="delete_image" phx-value-id={image.id} data-confirm="Delete this image?">
        Delete
      </.button>
    </div>
  </div>
</Layouts.app>
```

`~p` only verifies routes and static paths; uploaded files are neither, so build their URLs with a helper.

### Navigation

- [ ] `push_patch` / `<.link patch>` for the same LiveView with new params (only `handle_params/3` runs)
- [ ] `push_navigate` / `<.link navigate>` for another LiveView in the same `live_session` (no page reload; assigns are not carried over, flash is)
- [ ] `redirect/2` / `<.link href>` for a full page load (controller routes, other `live_session`s)
- [ ] Paths use `~p`

### Testing

Invoke the `testing-essentials` skill before writing the test file. Upload test shape:

```elixir
test "uploads and displays an image", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/gallery")

  upload =
    file_input(lv, "#upload-form", :images, [
      %{name: "test.png", content: File.read!("test/support/fixtures/test.png"), type: "image/png"}
    ])

  assert render_upload(upload, "test.png") =~ "100%"

  lv |> form("#upload-form", image: %{title: "Sunset"}) |> render_submit()

  assert has_element?(lv, "#images img[alt='Sunset']")
end
```

- [ ] `render_async(lv)` before asserting on async-loaded content
- [ ] Forms are targeted by their `id` (`form(lv, "#upload-form", ...)`)

### Performance

- [ ] Streams for anything that grows; `limit:` for feeds
- [ ] No queries in `render/1` or in function components
- [ ] Associations preloaded in the context, not lazily per row
- [ ] Async task functions capture plain values, not `socket` or `assigns`
- [ ] `phx-debounce` / `phx-throttle` on chatty events

### Common Pitfalls

- Subscribing in `handle_params/3` (duplicate messages after each `push_patch`)
- Context calls without the scope, or `Repo` calls in the LiveView
- Lists of records kept in assigns and updated with `update/3`
- Submit button inside an actions slot of `<.form>`, or a form without `id`
- `@current_user` (Phoenix 1.8 assigns `@current_scope`; the user is `@current_scope.user`)
- Changing the socket after `push_navigate/2` and expecting the next LiveView to see it
- `socket.assigns.x` in templates (use `@x`, which is change-tracked)

## LiveView JS Interop


> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

Read this when writing a client hook, exchanging events between a hook and the server, or adding
colocated JavaScript or CSS. The short version is in the skill's "JS Commands and Hooks" section.

Order of preference: plain bindings (`phx-click`, `phx-click-away`, `phx-window-keydown`) →
`Phoenix.LiveView.JS` commands → a colocated hook → a hook registered in `app.js`.

### Hooks

A hook is a JS object attached to an element with `phx-hook="Name"`. The element **must** have a
unique `id`; without one the client logs `no DOM ID for hook` and the hook never runs.

Callbacks: `mounted()`, `beforeUpdate(toEl)`, `updated()`, `destroyed()`, `disconnected()`,
`reconnected()`. Inside them:

| API | Purpose |
|---|---|
| `this.el` | The element |
| `this.pushEvent(event, payload)` | Send to the LiveView's `handle_event/3`; returns a promise of the `{:reply, map, socket}` payload |
| `this.pushEvent(event, payload, (reply, ref) => ...)` | Callback form |
| `this.pushEventTo(selectorOrTarget, event, payload)` | Send to the LiveView or LiveComponent that owns the target (e.g. `this.el` inside a component) |
| `this.handleEvent(event, payload => ...)` | Receive a `push_event/3` from the server; returns a ref for `removeHandleEvent(ref)` |
| `this.js()` | Run JS commands from the hook (`this.js().show(el)`, `this.js().exec(el, encodedJS)`) |
| `this.upload(name, files)` / `this.uploadTo(target, name, files)` | Feed files into an `allow_upload` config |

If the hook builds its own DOM inside `this.el`, add `phx-update="ignore"` so LiveView patches don't
wipe it. If it only needs to keep a few client-set attributes, use `JS.ignore_attributes/1` instead.

### Colocated hooks (`Phoenix.LiveView.ColocatedHook`, LiveView 1.1+)

```elixir
attr :share_url, :string, required: true

def copy_button(assigns) do
  ~H"""
  <div id="clipboard-btn" phx-hook=".Copy" data-text={@share_url}>Copy link</div>
  <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
    export default {
      mounted() {
        this.el.addEventListener("click", async () => {
          await navigator.clipboard.writeText(this.el.dataset.text)
          this.pushEvent("copied", {})
        })
      }
    }
  </script>
  """
end
```

- `name` must be a compile-time string starting with `.`; it's prefixed with the module name, so
  `.Copy` in two modules doesn't clash. Reference it with the same dotted name in `phx-hook`.
- Requires Phoenix 1.8+. New 1.8 apps already import the manifest in `assets/js/app.js`:
  `import {hooks as colocatedHooks} from "phoenix-colocated/my_app"` and
  `hooks: {...colocatedHooks}`. Upgraded apps must add both lines and the `NODE_PATH` entry
  (`Mix.Project.build_path()`) in the esbuild config.
- Hooks are extracted at compile time into `_build/$MIX_ENV/phoenix-colocated/`. A release alias
  must compile before bundling: `release: ["compile", "assets.deploy", "release"]`.
- Imports work: npm packages resolve normally; local files use the `@` alias
  (`import {x} from "@/vendor/foo"`), configured by default in 1.8's esbuild args.
- `runtime` attribute: the hook isn't bundled but evaluated in the browser (for pages like
  LiveDashboard that can't add to your bundle). Body is an object expression, not
  `export default`; under a CSP it needs `nonce={@script_csp_nonce}`. Avoid unless needed.

### Colocated JS (`Phoenix.LiveView.ColocatedJS`, LiveView 1.1+)

Same mechanism for non-hook code (web components, global listeners). The script's `export default`
becomes the key `name` on the default export of `phoenix-colocated/my_app`:

```elixir
def copy_button_script(assigns) do
  ~H"""
  <script :type={Phoenix.LiveView.ColocatedJS} name="CopyButton">
    export default class CopyButton extends HTMLElement {}
  </script>
  """
end
```

```javascript
import colocated from "phoenix-colocated/my_app"
customElements.define("copy-button", colocated.CopyButton)
```

### Colocated CSS (`Phoenix.LiveView.ColocatedCSS`, LiveView 1.2)

Not used directly: define a module that implements the behaviour, then use it as the `:type`.

```elixir
defmodule MyAppWeb.ColocatedCSS do
  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, _meta) do
    {:ok, css, []}
  end
end
```

```elixir
def price_table(assigns) do
  ~H"""
  <style :type={MyAppWeb.ColocatedCSS}>
    .price-table th { text-align: left; }
  </style>
  <table class="price-table">
    <tr><th>Plan</th></tr>
  </table>
  """
end
```

- The `<style>` tag must come first in the template.
- That module emits global CSS. For scoped CSS, return a `root_tag_attribute: {"phx-css-...", true}`
  directive and wrap the CSS in an `@scope` rule; the `Phoenix.LiveView.ColocatedCSS` moduledoc has a
  complete scoped implementation (it needs `config :phoenix_live_view, root_tag_attribute: "phx-r"`).
- Tailwind setup (Tailwind 4.2.3+, `:tailwind` 0.5+; default in apps generated with Phoenix 1.8.8+):
  `@import "phoenix-colocated/my_app/colocated.css";` and
  `@source "../../_build/dev/phoenix-colocated/my_app/*/";` in `assets/css/app.css`.

### Server → client: `push_event/4`

```elixir
{:noreply, push_event(socket, "chart:update", %{points: points})}
```

- Delivered to every hook that called `this.handleEvent("chart:update", ...)`, and dispatched on
  `window` as `phx:chart:update` (`window.addEventListener("phx:chart:update", e => e.detail)`).
- Dispatched after the DOM is patched; pass `dispatch: :before` to run before the patch.
- Payloads are JSON — don't push structs with fields the client shouldn't see.
- `JS` structs encode to JSON (LiveView 1.2), so you can push a command and run it in the hook:

```elixir
{:noreply, push_event(socket, "highlight", %{cmd: JS.transition("bg-yellow-100", to: "#row-#{id}")})}
```

```javascript
this.handleEvent("highlight", ({cmd}) => this.js().exec(this.el, cmd))
```

### Client → server with a reply

```javascript
const {label} = await this.pushEvent("chart:clicked", {index: 3})
```

```elixir
@impl true
def handle_event("chart:clicked", %{"index" => index}, socket) when is_integer(index) do
  {:reply, %{label: Enum.at(socket.assigns.labels, index)}, socket}
end
```

Treat hook payloads like any client input: validate types, and scope any record lookup with
`socket.assigns.current_scope`.

### `JS` commands quick reference

| Command | Notes |
|---|---|
| `JS.push(event, value: map, target: ...)` | Server event; chain client commands after it |
| `JS.show/hide/toggle(to:, transition:, time:)` | `display` toggling with optional transitions |
| `JS.add_class/remove_class/toggle_class(names, to:)` | Survive DOM patches |
| `JS.set_attribute({attr, val})`, `remove_attribute`, `toggle_attribute` | Attribute changes that survive patches |
| `JS.transition(classes_or_tuple, to:)` | One-off animation |
| `JS.dispatch(event, to:, detail:)` | Fire a DOM `CustomEvent` for vanilla JS listeners |
| `JS.navigate(path)` / `JS.patch(path)` | Client-initiated live navigation |
| `JS.focus`, `focus_first`, `push_focus`, `pop_focus` | Focus management for modals |
| `JS.exec("data-cancel", to: "#modal")` | Run a command stored in another element's attribute |
| `JS.ignore_attributes(attrs, to:)` | LiveView 1.1+: stop server patches to client-owned attributes (`"open"`, `"data-*"`) |

`phx-mounted={...}` runs a command when the element enters the DOM; `phx-remove={...}` runs one
before it leaves.

## Testing Reference


> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14, Req 0.7 — October 2026

Companion to the `testing-essentials` skill, which holds the rules and core patterns. This file has longer worked examples.

The examples use the `MyApp.Media` context and `Image` schema from the `ecto-essentials` and `phoenix-uploads` skills (images in folders), in the Phoenix 1.8 style: every context function takes the caller's `%Scope{}` first; `Image.changeset/3` casts only `title` and `original_name` and sets `user_id` from the scope; `create_image(scope, tmp_path, attrs)` sniffs and stores the file and sets `filename`, `content_type` and `byte_size` itself.

---

### Fixtures

Fixtures live in `test/support/fixtures/` and go through the real context, so validations and scoping are exercised.

```elixir
defmodule MyApp.MediaFixtures do
  @moduledoc "Test helpers for the Media context."

  alias MyApp.Media

  # A real PNG: create_image/3 checks the magic bytes.
  def png_path, do: Path.join(__DIR__, "test.png")

  def unique_image_title, do: "Image #{System.unique_integer([:positive])}"

  def valid_image_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{title: unique_image_title(), original_name: "test.png"})
  end

  def image_fixture(scope, attrs \\ %{}) do
    {:ok, image} = Media.create_image(scope, png_path(), valid_image_attributes(attrs))
    image
  end

  def folder_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "Folder #{System.unique_integer([:positive])}"})
    {:ok, folder} = Media.create_folder(scope, attrs)
    folder
  end
end
```

`test/support/fixtures/test.png` must be a real PNG. `create_image/3` copies it into the test `:uploads_dir` (`tmp/test_uploads`, configured as in the `phoenix-uploads` skill); the server-generated UUID names keep async tests from colliding there.

---

### Context Tests

```elixir
defmodule MyApp.MediaTest do
  use MyApp.DataCase, async: true

  alias MyApp.Media
  alias MyApp.Media.Image

  import MyApp.AccountsFixtures, only: [user_scope_fixture: 0]
  import MyApp.MediaFixtures

  setup do
    %{scope: user_scope_fixture()}
  end

  describe "list_images/2" do
    test "returns only the scope's images", %{scope: scope} do
      image = image_fixture(scope)
      _others = image_fixture(user_scope_fixture())

      assert [%Image{id: id}] = Media.list_images(scope)
      assert id == image.id
    end

    test "returns an empty list when the user has no images", %{scope: scope} do
      assert Media.list_images(scope) == []
    end

    test "folder_id: returns only images in that folder", %{scope: scope} do
      folder = folder_fixture(scope)
      {:ok, in_folder} = Media.move_image(scope, image_fixture(scope), folder.id)
      _loose = image_fixture(scope)

      assert [%Image{id: id}] = Media.list_images(scope, folder_id: folder.id)
      assert id == in_folder.id
    end
  end

  describe "create_image/3" do
    test "stores the file and creates an image owned by the scope", %{scope: scope} do
      attrs = valid_image_attributes(title: "Sunset")

      assert {:ok, %Image{} = image} = Media.create_image(scope, png_path(), attrs)
      assert image.title == "Sunset"
      assert image.content_type == "image/png"
      assert image.user_id == scope.user.id
    end

    test "ignores user_id and storage fields in the params", %{scope: scope} do
      other = user_scope_fixture()
      attrs = valid_image_attributes(user_id: other.user.id, filename: "../../evil.html")

      assert {:ok, image} = Media.create_image(scope, png_path(), attrs)
      assert image.user_id == scope.user.id
      refute image.filename == "../../evil.html"
    end

    @tag :tmp_dir
    test "rejects a file that isn't an image", %{scope: scope, tmp_dir: dir} do
      path = Path.join(dir, "fake.png")
      File.write!(path, "<script>alert(1)</script>")

      assert {:error, :invalid_content} = Media.create_image(scope, path, valid_image_attributes())
    end

    test "with invalid attributes returns an error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Media.create_image(scope, png_path(), %{title: ""})

      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "update_image/3" do
    test "with valid attributes updates the image", %{scope: scope} do
      image = image_fixture(scope)

      assert {:ok, %Image{} = updated} = Media.update_image(scope, image, %{title: "Updated"})
      assert updated.title == "Updated"
    end
  end

  describe "move_image/3" do
    test "refuses a folder owned by someone else", %{scope: scope} do
      image = image_fixture(scope)
      foreign = folder_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn -> Media.move_image(scope, image, foreign.id) end
    end
  end

  describe "delete_image/2" do
    test "deletes the image", %{scope: scope} do
      image = image_fixture(scope)

      assert {:ok, %Image{}} = Media.delete_image(scope, image)
      assert_raise Ecto.NoResultsError, fn -> Media.get_image!(scope, image.id) end
    end

    test "can't reach another user's image", %{scope: scope} do
      image = image_fixture(user_scope_fixture())
      assert_raise Ecto.NoResultsError, fn -> Media.get_image!(scope, image.id) end
    end
  end
end
```

Compare by id (or `Repo.reload`) when the struct you hold and the one the query returns may differ in preloads or virtual fields.

---

### Schema and Changeset Tests

```elixir
defmodule MyApp.Media.ImageTest do
  use MyApp.DataCase, async: true

  alias MyApp.Media.Image
  import MyApp.AccountsFixtures, only: [user_scope_fixture: 0]

  # Storage fields are set on the struct by the upload code, never cast.
  @stored %Image{filename: "a.png", content_type: "image/png", byte_size: 1024}

  setup do
    %{scope: user_scope_fixture()}
  end

  test "valid attributes", %{scope: scope} do
    changeset = Image.changeset(@stored, %{title: "Test"}, scope)
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :user_id) == scope.user.id
  end

  test "requires title", %{scope: scope} do
    changeset = Image.changeset(@stored, %{}, scope)
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end

  test "limits title length", %{scope: scope} do
    changeset = Image.changeset(@stored, %{title: String.duplicate("a", 256)}, scope)
    assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
  end

  test "does not cast storage fields", %{scope: scope} do
    changeset = Image.changeset(%Image{}, %{title: "T", filename: "x.html", byte_size: 1}, scope)
    assert %{filename: ["can't be blank"], byte_size: ["can't be blank"]} = errors_on(changeset)
  end
end
```

---

### LiveView Tests

The gallery lists images as a stream (`id="images"`, rows `images-<id>`), has a folder form and a per-image "move" form.

```elixir
defmodule MyAppWeb.GalleryLiveTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MyApp.MediaFixtures

  alias MyApp.Media

  setup :register_and_log_in_user

  test "displays the user's images only", %{conn: conn, scope: scope} do
    image = image_fixture(scope, title: "Sunset")
    other = image_fixture(MyApp.AccountsFixtures.user_scope_fixture(), title: "Not mine")

    {:ok, lv, _html} = live(conn, ~p"/gallery")

    assert has_element?(lv, "#images-#{image.id}", "Sunset")
    refute has_element?(lv, "#images-#{other.id}")
  end

  test "deletes an image", %{conn: conn, scope: scope} do
    image = image_fixture(scope, title: "To Delete")
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    lv |> element("#images-#{image.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#images-#{image.id}")
  end

  test "creates a folder", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    lv |> form("#folder-form", folder: %{name: "Vacation"}) |> render_submit()

    assert has_element?(lv, "#folders", "Vacation")
  end

  test "moves an image to a folder", %{conn: conn, scope: scope} do
    image = image_fixture(scope)
    folder = folder_fixture(scope, name: "Vacation")
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    # The submit must carry the selection itself: render_submit/1 sends the form as
    # rendered, not what an earlier render_change sent.
    lv
    |> form("#move-image-#{image.id}", image: %{folder_id: folder.id})
    |> render_submit()

    assert Media.get_image!(scope, image.id).folder_id == folder.id
  end

  test "navigates to a folder", %{conn: conn, scope: scope} do
    folder = folder_fixture(scope, name: "Vacation")
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    {:ok, folder_lv, _html} =
      lv
      |> element("#folders-#{folder.id} a")
      |> render_click()
      |> follow_redirect(conn, ~p"/gallery/folders/#{folder}")

    assert has_element?(folder_lv, "h1", "Vacation")
  end
end
```

`form/3` checks your data against the markup: the `<select>` must contain an option whose value is `folder.id` (integers are compared as strings), or it raises `ArgumentError`. That makes the test fail if the user's folders aren't offered.

#### Async assigns, patches and hooks

```elixir
test "loads stats asynchronously", %{conn: conn} do
  {:ok, lv, html} = live(conn, ~p"/gallery")
  assert html =~ "Loading stats"
  assert render_async(lv, 500) =~ "images total"
end

test "sorting patches the URL", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/gallery")
  lv |> element("a", "Newest first") |> render_click()
  assert_patch(lv, ~p"/gallery?sort=newest")
end

test "a JS hook reorders images", %{conn: conn, scope: scope} do
  [a, b] = [image_fixture(scope), image_fixture(scope)]
  {:ok, lv, _html} = live(conn, ~p"/gallery")

  render_hook(lv, "reorder", %{"ids" => [b.id, a.id]})

  assert [b.id, a.id] == Enum.map(Media.list_images(scope), & &1.id)
end
```

#### Components and LiveViews without a route

`live_isolated/3` mounts a LiveView without the router, so the `live_session`'s `on_mount` hooks don't run: `@current_scope` is not assigned (a generated LiveView raises `KeyError`) unless the module declares its own `on_mount`. It suits self-contained LiveViews; pass extra data to `mount/3` with `:session`.

```elixir
{:ok, lv, _html} =
  live_isolated(conn, MyAppWeb.UploadDemoLive, session: %{"max_entries" => 3})
```

Function components can be rendered with `render_component/3`:

```elixir
assert render_component(&MyAppWeb.MediaComponents.status_badge/1, status: :draft) =~ "Draft"
```

---

### Upload Tests

`file_input/4` only builds the upload; nothing reaches the server until `render_upload/3`. On rejection `render_upload/3` returns `{:error, [[entry_ref, reason]]}` with `:not_accepted`, `:too_large` or `:too_many_files`, so assert on that return value instead of the rendered page.

```elixir
describe "uploads" do
  setup :register_and_log_in_user

  test "uploads and saves an image", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    upload =
      file_input(lv, "#upload-form", :images, [
        %{name: "test.png", content: File.read!("test/support/fixtures/test.png"), type: "image/png"}
      ])

    assert render_upload(upload, "test.png") =~ "100%"

    lv |> form("#upload-form", image: %{title: "Test Upload"}) |> render_submit()

    assert has_element?(lv, "#images img[alt='Test Upload']")
  end

  test "rejects a file type outside :accept", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    pdf =
      file_input(lv, "#upload-form", :images, [
        %{name: "test.pdf", content: "fake pdf", type: "application/pdf"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(pdf, "test.pdf")
  end

  test "rejects a file over :max_file_size", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    # allow_upload(:images, max_file_size: 10_000_000)
    large =
      file_input(lv, "#upload-form", :images, [
        %{name: "large.jpg", content: :binary.copy(<<0>>, 10_000_001), type: "image/jpeg"}
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(large, "large.jpg")
  end
end
```

`render_upload/3` does not consume the entry; call `render_submit` before asserting anything that `consume_uploaded_entries/3` does.

---

### Async Tests and the SQL Sandbox

`DataCase` and `ConnCase` call `Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: not tags[:async])`, so each async test gets its own transaction that is rolled back on exit.

```elixir
defmodule MyApp.Media.QueriesTest do
  use MyApp.DataCase, async: true   # DataCase has no conn — use ConnCase for HTTP/LiveView

  test "counts images per user" do
    scope = MyApp.AccountsFixtures.user_scope_fixture()
    MyApp.MediaFixtures.image_fixture(scope)
    assert MyApp.Media.count_images(scope) == 1
  end
end
```

Use `async: false` only when the test touches truly shared state:

- `Application.put_env/3` or other global config
- named processes, ETS tables or anything in the application's supervision tree
- Mox or `Req.Test` in global/shared mode
- the filesystem outside `@tag :tmp_dir`

#### Processes outside the test tree

Which processes can use the test's sandbox connection in an async test:

| Process | Sandbox access |
|---|---|
| the test process | yes (owner) |
| `Task.async`/`Task.Supervisor` started from the test | yes, via `$callers` |
| LiveViews started by `live/2`; channels joined with `subscribe_and_join` | yes, via `$callers` |
| a GenServer started with `start_supervised!` | **no** — call `allow/3` |
| a process already running in the app tree (cache, PubSub listener) | **no** — `allow/3`, or `async: false` |

```elixir
test "the indexer reads the new image", %{scope: scope} do
  pid = start_supervised!(MyApp.Indexer)
  Ecto.Adapters.SQL.Sandbox.allow(MyApp.Repo, self(), pid)

  image = MyApp.MediaFixtures.image_fixture(scope)
  assert :ok = MyApp.Indexer.index(pid, image.id)
end
```

Without the allowance the GenServer fails with `DBConnection.OwnershipError` ("cannot find ownership process"). Browser-driven tests (Wallaby, PhoenixTest.Playwright) need `Phoenix.Ecto.SQL.Sandbox` in the endpoint to pass the owner through the user agent.

---

### Mox in Full

1. Add the dependency: `{:mox, "~> 1.2", only: :test}`.
2. Define a behaviour and route calls through a configured implementation:

```elixir
defmodule MyApp.Storage do
  @callback put(key :: String.t(), data :: binary()) :: {:ok, String.t()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  def put(key, data), do: impl().put(key, data)
  def delete(key), do: impl().delete(key)

  defp impl, do: Application.get_env(:my_app, :storage, MyApp.Storage.S3)
end

defmodule MyApp.Storage.S3 do
  @behaviour MyApp.Storage

  @impl true
  def put(key, _data) do
    # the real upload (Req / ExAws) goes here
    {:ok, "https://bucket.example/#{key}"}
  end

  @impl true
  def delete(_key), do: :ok
end
```

3. Swap it in tests and define the mock:

```elixir
# config/test.exs
config :my_app, :storage, MyApp.StorageMock

# test/test_helper.exs
Mox.defmock(MyApp.StorageMock, for: MyApp.Storage)
ExUnit.start()
```

4. Use it with `verify_on_exit!` so unmet expectations fail:

```elixir
defmodule MyApp.MediaStorageTest do
  use MyApp.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  # Assumes a Media context whose store_file/1 and delete_image/2 go through MyApp.Storage.
  test "delete_image/2 removes the stored file" do
    scope = MyApp.AccountsFixtures.user_scope_fixture()
    stub(MyApp.StorageMock, :put, fn key, _data -> {:ok, "https://cdn.example/#{key}"} end)
    image = MyApp.MediaFixtures.image_fixture(scope)
    filename = image.filename

    expect(MyApp.StorageMock, :delete, fn ^filename -> :ok end)

    assert {:ok, _} = MyApp.Media.delete_image(scope, image)
  end
end
```

- `expect/4` must be called exactly N times; `stub/3` may be called any number of times. `stub_with(MyApp.StorageMock, MyApp.Storage.Fake)` stubs every callback from a module.
- Expectations belong to the test process. `Task`s inherit them via `$callers`; for a GenServer, `Mox.allow(MyApp.StorageMock, self(), pid)`. If you can't get the pid, use `setup :set_mox_from_context` with `async: false` (global mode).
- Prefer `Application.get_env/3` at call time over `Application.compile_env/3` when tests may need to swap the implementation per test.

---

### Req.Test in Full

With `plug: {Req.Test, MyApp.Weather}` (and `retry: false`) in the test config, as in the skill:

```elixir
defmodule MyApp.WeatherTest do
  use ExUnit.Case, async: true

  setup {Req.Test, :verify_on_exit!}

  test "sends the city and parses the reply" do
    Req.Test.expect(MyApp.Weather, fn conn ->
      assert conn.method == "GET"
      assert conn.params["city"] == "Lisbon"
      Req.Test.json(conn, %{"celsius" => 21.5})
    end)

    assert {:ok, 21.5} = MyApp.Weather.celsius("Lisbon")
  end

  test "maps a 503 to an error" do
    Req.Test.stub(MyApp.Weather, &Plug.Conn.send_resp(&1, 503, "down"))
    assert {:error, {:http, 503}} = MyApp.Weather.celsius("Lisbon")
  end

  test "a transport error, then a good reply" do
    Req.Test.expect(MyApp.Weather, &Req.Test.transport_error(&1, :econnrefused))
    Req.Test.expect(MyApp.Weather, &Req.Test.json(&1, %{"celsius" => 3.0}))

    assert {:error, %Req.TransportError{}} = MyApp.Weather.celsius("Oslo")
    assert {:ok, 3.0} = MyApp.Weather.celsius("Oslo")
  end
end
```

`Req.Test.expect/3` registrations are consumed in order. For a request made from a GenServer, `Req.Test.allow(MyApp.Weather, self(), pid)`.

---

### Property-Based Tests (StreamData)

Add `{:stream_data, "~> 1.1", only: [:dev, :test]}`. Good for parsers, encoders and invariants that should hold for any input.

```elixir
defmodule MyApp.SlugTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "slugify/1 output is URL-safe and idempotent" do
    check all title <- string(:printable, min_length: 1) do
      slug = MyApp.Slug.slugify(title)
      assert slug =~ ~r/\A[a-z0-9-]*\z/
      assert MyApp.Slug.slugify(slug) == slug
    end
  end
end
```

---

### Common Assertions

```elixir
assert {:ok, %Image{}} = result                      # pattern match
assert_raise Ecto.NoResultsError, fn -> Media.get_image!(scope, id) end
assert Repo.aggregate(Image, :count) == 1
assert "can't be blank" in errors_on(changeset).title

assert has_element?(lv, "#images-#{image.id}")       # LiveView structure
assert render(lv) =~ "Successfully created"          # flash text on the current page
assert_receive {:created, %Image{}}, 500            # PubSub / messages
refute_received {:deleted, _}
```

---

### Test Organization

```
test/
├── my_app/
│   ├── media_test.exs              # context tests
│   └── media/
│       └── image_test.exs          # schema/changeset tests
├── my_app_web/
│   ├── live/
│   │   └── gallery_live_test.exs
│   └── controllers/
│       └── page_controller_test.exs
├── support/
│   ├── conn_case.ex
│   ├── data_case.ex
│   └── fixtures/
│       ├── accounts_fixtures.ex    # generated by phx.gen.auth
│       ├── media_fixtures.ex
│       └── test.png
└── test_helper.exs                 # Mox.defmock calls go here
```
