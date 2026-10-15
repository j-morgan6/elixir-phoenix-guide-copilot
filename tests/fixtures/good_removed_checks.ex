defmodule AppWeb.Layouts do
  use AppWeb, :html

  # Patterns that earlier Copilot-only checks flagged but that are valid code.
  def app(assigns) do
    ~H"""
    <main>{render_slot(@inner_block)}</main>
    <.flash_group flash={@flash} />
    """
  end

  def classify(user) do
    if user.admin? do
      if user.active?, do: :active_admin, else: :inactive_admin
    else
      :user
    end
  end

  def labels(items) do
    items
    |> Enum.filter(& &1.visible)
    |> Enum.map(fn item -> "#" <> item.name end)
  end

  def fetch(id) do
    with {:ok, post} <- App.Blog.fetch_post(id) do
      post.comments
    end
  end

  def mount_upload(socket) do
    upload_path = "/uploads/"
    max_file_size = 10000000
    socket
    |> allow_upload(:avatar, accept: ~w(.jpg), auto_upload: true, max_file_size: max_file_size)
    |> assign(:upload_path, upload_path)
  end

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def announce(msg), do: IO.puts("note: " <> msg)
end
